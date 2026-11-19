#!/usr/bin/env python3
"""Run the pull-request fixtures through a real terraform plan + the conftest gate.

For every fixture the runner copies terraform/ into a scratch workspace,
applies the fixture (tfvars, extra .tf, or edits to module code), runs
`terraform plan` against the environment's remote state, converts the plan
with `terraform show -json`, and evaluates policy/terraform with conftest.

A baseline (no change) plan runs first and must produce zero denials.

    uv run --with-requirements experiments/requirements.txt experiments/policy/run.py --env local
    uv run ... experiments/policy/run.py --env dev     # against real AWS state, read-only plans
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib import RESULTS, ROOT, WORK, log, summarize, write_json  # noqa: E402

FIXTURES = Path(__file__).with_name("fixtures.yaml")
RULE_ID = re.compile(r"^(TF\d{3})\b")


def tf_output(stack_dir: Path, name: str) -> str:
    return subprocess.run(["terraform", f"-chdir={stack_dir}", "output", "-raw", name],
                          check=True, capture_output=True, text=True).stdout.strip()


def stack_settings(env: str) -> dict:
    boot = ROOT / "terraform" / "bootstrap"
    if env == "local":
        return {
            "infra": {
                "dir": "live/infra",
                "init": ["-backend-config=../local.backend.hcl", "-backend-config=key=local/infra.tfstate"],
                "vars": ["-var-file=env/local.tfvars"],
            },
            "bootstrap": {
                "dir": "bootstrap",
                "init": [],
                "vars": ["-var", "aws_endpoint=https://127.0.0.1:15566",
                         "-var", "state_bucket_name=eks-gitops-tfstate-local", "-var", "force_destroy_state=true"],
                "state": boot / "terraform.tfstate",
            },
        }
    return {
        "infra": {
            "dir": "live/infra",
            "init": [f"-backend-config=../backend-{env}.hcl", f"-backend-config=key={env}/infra.tfstate"],
            "vars": [f"-var-file=env/{env}.tfvars",
                     "-var", f"permissions_boundary_arn={tf_output(boot, 'permissions_boundary_arn')}",
                     "-var", "public_access_cidrs=[\"" + subprocess.run(
                         ["curl", "-s", "https://checkip.amazonaws.com"], capture_output=True, text=True).stdout.strip() + "/32\"]"],
        },
        "bootstrap": {"dir": "bootstrap", "init": [], "vars": [], "state": boot / "terraform.tfstate"},
    }


def make_workspace(fx: dict, settings: dict) -> Path:
    ws = WORK / "policy" / fx["id"]
    if ws.exists():
        shutil.rmtree(ws)
    shutil.copytree(
        ROOT / "terraform", ws / "terraform",
        ignore=shutil.ignore_patterns(".terraform", "terraform.tfstate*", "*.tfplan", "*.tfplan.json"),
    )
    stack = settings[fx["stack"]]
    sdir = ws / "terraform" / stack["dir"]
    if stack.get("state"):
        shutil.copy(stack["state"], sdir / "terraform.tfstate")
    for p in fx.get("patch", []):
        f = ws / "terraform" / p["file"]
        text = f.read_text()
        if p["find"] not in text:
            raise ValueError(f"{fx['id']}: patch target not found in {p['file']}: {p['find']!r}")
        f.write_text(text.replace(p["find"], p["replace"], 1))
    if fx.get("add"):
        (sdir / "zz_fixture.tf").write_text(fx["add"])
    if fx.get("tfvars"):
        (sdir / "zz_fixture.tfvars").write_text(fx["tfvars"])
    return sdir


def run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)


def evaluate(fx: dict, settings: dict) -> dict:
    t0 = time.time()
    rec = {"id": fx["id"], "name": fx["name"], "stack": fx["stack"], "expect": fx.get("expect", [])}
    sdir = make_workspace(fx, settings)
    stack = settings[fx["stack"]]
    env = {**os.environ, "TF_IN_AUTOMATION": "1",
           "TF_PLUGIN_CACHE_DIR": str(Path.home() / ".terraform.d" / "plugin-cache")}
    Path(env["TF_PLUGIN_CACHE_DIR"]).mkdir(parents=True, exist_ok=True)

    init = run(["terraform", "init", "-input=false", "-no-color", *stack["init"]], cwd=sdir, env=env)
    if init.returncode:
        rec.update(verdict="ERROR", error="init: " + init.stderr[-800:])
        return rec
    var_args = list(stack["vars"])
    if (sdir / "zz_fixture.tfvars").exists():
        var_args.append("-var-file=zz_fixture.tfvars")
    plan = run(["terraform", "plan", "-input=false", "-no-color", "-lock=false", "-out=plan.tfplan", *var_args],
               cwd=sdir, env=env)
    if plan.returncode:
        rec.update(verdict="ERROR", error="plan: " + (plan.stderr or plan.stdout)[-1500:])
        return rec
    show = run(["terraform", "show", "-json", "plan.tfplan"], cwd=sdir, env=env)
    (sdir / "plan.json").write_text(show.stdout)
    doc = json.loads(show.stdout)
    actions = [tuple(rc["change"]["actions"]) for rc in doc.get("resource_changes", [])]
    rec["plan"] = {
        "create": sum(a == ("create",) for a in actions),
        "update": sum(a == ("update",) for a in actions),
        "delete": sum(a == ("delete",) for a in actions),
        "replace": sum(len(a) == 2 for a in actions),
    }

    ct = run(["conftest", "test", str(sdir / "plan.json"), "--policy", str(ROOT / "policy" / "terraform"),
              "--data", str(ROOT / "policy" / "data"), "--output", "json", "--no-color"])
    results = json.loads(ct.stdout or "[]")
    messages = [f["msg"] for r in results for f in (r.get("failures") or [])]
    found = sorted({m.group(1) for msg in messages if (m := RULE_ID.match(msg))})
    rec["found"] = found
    rec["messages"] = messages
    expect = set(rec["expect"])
    if expect:
        rec["verdict"] = "BLOCKED" if expect <= set(found) else "MISSED"
    else:
        rec["verdict"] = "PASSED" if not found else "FALSE_POSITIVE"
    rec["seconds"] = round(time.time() - t0, 1)
    return rec


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default="local")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--only", default="", help="comma-separated fixture ids")
    args = ap.parse_args()

    fixtures = yaml.safe_load(FIXTURES.read_text())
    if args.only:
        wanted = set(args.only.split(","))
        fixtures = [f for f in fixtures if f["id"] in wanted]
    skipped = []
    if args.env == "local":
        skipped = [f["id"] for f in fixtures if f.get("requires") == "aws"]
        fixtures = [f for f in fixtures if f.get("requires") != "aws"]
    settings = stack_settings(args.env)
    baselines = [{"id": f"B-{s}", "name": f"baseline plan ({s}, no change)", "stack": s, "expect": []}
                 for s in ("infra", "bootstrap")]

    started = dt.datetime.now(dt.timezone.utc)
    # Baselines run first and alone: they fill the shared provider plugin
    # cache, which parallel `terraform init`s would otherwise race on.
    results = [evaluate(b, settings) for b in baselines]
    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool:
        results += list(pool.map(lambda f: evaluate(f, settings), fixtures))
    for r in results:
        log(f"{r['id']:10s} {r['verdict']:15s} expect={','.join(r['expect']) or '-':10s} "
            f"found={','.join(r.get('found', [])) or '-':22s} {r['name']}")
        if r["verdict"] == "ERROR":
            log("    " + r["error"].strip().replace("\n", "\n    ")[-1200:])

    unsafe = [r for r in results if r["expect"]]
    safe = [r for r in results if not r["expect"]]
    summary = {
        "env": args.env,
        "started": started.isoformat(),
        "unsafe_changes": len(unsafe),
        "blocked": sum(r["verdict"] == "BLOCKED" for r in unsafe),
        "missed": [r["id"] for r in unsafe if r["verdict"] == "MISSED"],
        "safe_changes": len(safe),
        "passed": sum(r["verdict"] == "PASSED" for r in safe),
        "false_positives": [r["id"] for r in safe if r["verdict"] == "FALSE_POSITIVE"],
        "errors": [r["id"] for r in results if r["verdict"] == "ERROR"],
        "skipped_needs_aws": skipped,
        "rules_exercised": sorted({x for r in unsafe for x in r.get("found", [])}),
        "seconds_per_fixture": summarize([r["seconds"] for r in results if "seconds" in r]),
    }
    stamp = started.strftime("%Y%m%dT%H%M%SZ")
    write_json(RESULTS / args.env / f"policy-{stamp}.json", {"summary": summary, "fixtures": results})
    print(yaml.safe_dump(summary, sort_keys=False))
    sys.exit(0 if not (summary["missed"] or summary["false_positives"] or summary["errors"]) else 1)


if __name__ == "__main__":
    main()
