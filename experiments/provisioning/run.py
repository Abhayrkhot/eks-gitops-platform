#!/usr/bin/env python3
"""Time end-to-end platform provisioning: empty account -> every app Healthy.

One cycle =
  infra    terraform apply of terraform/live/infra (VPC, EKS, node group, add-ons)
  access   aws eks update-kubeconfig into the environment's own kubeconfig
  gitops   terraform apply of terraform/live/gitops (Argo CD + root app)
  converge Argo CD syncs every app from Git until all are Synced+Healthy
then `make down` is timed as teardown. Per-resource create times are parsed
from Terraform's "Creation complete after" lines, which shows the critical path.

    uv run --with-requirements experiments/requirements.txt experiments/provisioning/run.py --env dev --cycles 3
    uv run ... experiments/provisioning/run.py --env dev --baseline   # sequential CLI runbook instead
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib import RESULTS, ROOT, WORK, log, summarize, write_json  # noqa: E402

CREATED = re.compile(r"^(?P<addr>\S+): Creation complete after (?P<dur>[0-9hms]+)")
DESTROYED = re.compile(r"^(?P<addr>\S+): Destruction complete after (?P<dur>[0-9hms]+)")
# baseline-runbook.sh stamps each step: "[HH:MM:SS] 3/5 EKS cluster" ... "[HH:MM:SS] runbook complete"
STAMP = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] (?:\d/\d )?(?P<label>.+)$")
# Runbook steps grouped like the Terraform phases, so the comparison lines up.
RUNBOOK_INFRA = ("VPC stack", "cluster role", "EKS cluster", "node role + node group")
RUNBOOK_GITOPS = ("Argo CD + root app",)


def runbook_steps(output: str) -> dict[str, int]:
    """Seconds per runbook step, from consecutive step stamps (1s resolution)."""
    marks = []
    for line in output.splitlines():
        m = STAMP.match(line.strip())
        if m:
            h, mi, s = (int(x) for x in m.groups()[:3])
            marks.append((h * 3600 + mi * 60 + s, m["label"]))
    return {label: (t1 - t0) % 86400 for (t0, label), (t1, _) in zip(marks, marks[1:])}


def seconds(d: str) -> int:
    total = 0
    for value, unit in re.findall(r"(\d+)([hms])", d):
        total += int(value) * {"h": 3600, "m": 60, "s": 1}[unit]
    return total


def step(name: str, cmd: list[str], logfile: Path, env: dict) -> tuple[float, str]:
    t0 = time.time()
    with logfile.open("a") as fh:
        fh.write(f"\n===== {name}: {' '.join(cmd)}\n")
        proc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        fh.write(proc.stdout)
    took = time.time() - t0
    if proc.returncode:
        raise RuntimeError(f"{name} failed after {took:.0f}s; see {logfile}")
    log(f"  {name:9s} {took:7.1f}s")
    return took, proc.stdout


def critical(output: str, pattern: re.Pattern) -> dict[str, int]:
    out = {}
    for line in output.splitlines():
        m = pattern.match(line.strip())
        if m:
            out[m["addr"]] = seconds(m["dur"])
    return dict(sorted(out.items(), key=lambda kv: -kv[1])[:8])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default="dev")
    ap.add_argument("--cycles", type=int, default=3)
    ap.add_argument("--baseline", action="store_true", help="time the sequential CLI runbook instead")
    ap.add_argument("--keep-last", action="store_true", help="leave the platform up after the last cycle")
    args = ap.parse_args()

    env = {**os.environ, "ENV": args.env}
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    logfile = WORK / f"provisioning-{args.env}-{stamp}.log"
    logfile.parent.mkdir(parents=True, exist_ok=True)
    cycles = []
    for i in range(1, args.cycles + 1):
        log(f"cycle {i}/{args.cycles} ({'baseline runbook' if args.baseline else 'terraform modules'})")
        rec: dict = {"cycle": i}
        t0 = time.time()
        if args.baseline:
            rec["up_s"], up_out = step("runbook", ["experiments/provisioning/baseline-runbook.sh", "up"], logfile, env)
            rec["steps_s"] = runbook_steps(up_out)
            rec["infra_s"] = sum(rec["steps_s"].get(k, 0) for k in RUNBOOK_INFRA)
            rec["platform_s"] = sum(rec["steps_s"].get(k, 0) for k in RUNBOOK_GITOPS)
            log("  steps     " + ", ".join(f"{k} {v}s" for k, v in rec["steps_s"].items()))
        else:
            rec["infra_s"], infra_out = step("infra", ["make", "infra", f"ENV={args.env}"], logfile, env)
            rec["access_s"], _ = step("access", ["make", "kubeconfig", f"ENV={args.env}"], logfile, env)
            rec["gitops_s"], gitops_out = step("gitops", ["make", "gitops", f"ENV={args.env}"], logfile, env)
            rec["converge_s"], _ = step("converge", ["make", "wait", f"ENV={args.env}"], logfile, env)
            rec["slowest_resources_s"] = critical(infra_out + gitops_out, CREATED)
        rec["platform_ready_s"] = round(time.time() - t0, 1)
        log(f"  READY     {rec['platform_ready_s']:7.1f}s ({rec['platform_ready_s'] / 60:.1f} min)")
        if args.keep_last and i == args.cycles:
            cycles.append(rec)
            break
        if args.baseline:
            rec["teardown_s"], _ = step("teardown", ["experiments/provisioning/baseline-runbook.sh", "down"], logfile, env)
        else:
            rec["teardown_s"], down_out = step("teardown", ["make", "down", f"ENV={args.env}"], logfile, env)
            rec["slowest_destroys_s"] = critical(down_out, DESTROYED)
        cycles.append(rec)

    summary = {
        "env": args.env,
        "method": "sequential CLI runbook" if args.baseline else "terraform modules + gitops",
        "cycles": len(cycles),
        "platform_ready_minutes": summarize([c["platform_ready_s"] / 60 for c in cycles]),
        "teardown_minutes": summarize([c["teardown_s"] / 60 for c in cycles if "teardown_s" in c]),
    }
    if args.baseline:
        summary["infra_seconds"] = summarize([c["infra_s"] for c in cycles])
        summary["platform_seconds"] = summarize([c["platform_s"] for c in cycles])
        summary["steps_seconds"] = {k: summarize([c["steps_s"][k] for c in cycles if k in c["steps_s"]])
                                    for k in RUNBOOK_INFRA + RUNBOOK_GITOPS}
    else:
        for phase in ("infra_s", "access_s", "gitops_s", "converge_s"):
            summary[phase.replace("_s", "_seconds")] = summarize([c[phase] for c in cycles])
        # Same grouping as the runbook: everything after the AWS resources exist.
        summary["platform_seconds"] = summarize([c["access_s"] + c["gitops_s"] + c["converge_s"] for c in cycles])
    name = "provisioning-baseline" if args.baseline else "provisioning"
    write_json(RESULTS / args.env / f"{name}-{stamp}.json", {"summary": summary, "cycles": cycles})
    print(yaml.safe_dump(summary, sort_keys=False))


if __name__ == "__main__":
    main()
