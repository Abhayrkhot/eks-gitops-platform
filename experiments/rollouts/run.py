#!/usr/bin/env python3
"""Failed-release recovery experiment for the storefront canary.

Every trial is a real GitOps release: the harness rewrites
gitops/charts/storefront/release.yaml in the lab Git repo, commits, pushes,
and Argo CD syncs it (push webhook). Argo Rollouts then has to catch the bad
release and put the stable version back on its own; the harness only watches.

For a bad release it records
  t_push       commit pushed to Git
  t_detect     Rollouts first reconciles the new revision (canary ReplicaSet exists)
  t_abort      rollout aborted (analysis failed or progress deadline hit)
  t_isolated   canary pods gone: every client request lands on the stable version
  t_recovered  canary scaled to zero AND the stable ReplicaSet back at full
               availability, with the stable Service still on the stable hash
and the client requests (from the loadgen pod) that failed in between.
After each bad release the harness reverts Git to the last good release.

Good releases are interleaved to show the guardrails do not block healthy
changes (false positives).

    KUBECONFIG=~/.kube/egp-gitops.yaml uv run --with-requirements experiments/requirements.txt \
        experiments/rollouts/run.py --env local --per-mode 10 --good 10
"""

from __future__ import annotations

import argparse
import datetime as dt
import random
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib import RESULTS, LabGit, kube, log, now, port_forward, summarize, write_json  # noqa: E402

NS = "storefront"
NAME = "storefront"
RELEASE_FILE = "gitops/charts/storefront/release.yaml"
GOOD_TAGS = ["6.16.0", "6.17.0"]

# Each fault is a release.yaml change a real team could ship by mistake.
FAULTS: dict[str, dict] = {
    "crash-loop": {"command": ["sh", "-c", "echo 'fatal: cannot parse config' >&2; exit 1"]},
    "bad-image-tag": {"tag": "6.17.0-does-not-exist"},
    "oom-on-start": {"args": ["--stress-memory=512"]},
    "never-ready": {"args": ["--unready"]},
    "failing-liveness": {"args": ["--unhealthy"]},
    "http-500s": {"args": ["--random-error"]},
    "slow-responses": {"args": ["--random-delay", "--random-delay-unit=ms",
                                "--random-delay-min=400", "--random-delay-max=900"]},
}


class Cluster:
    def __init__(self):
        _, self.core, self.apps, self.co = kube()

    def rollout(self) -> dict:
        return self.co.get_namespaced_custom_object("argoproj.io", "v1alpha1", NS, "rollouts", NAME)

    def replicasets(self) -> dict:
        items = self.apps.list_namespaced_replica_set(NS, label_selector="app.kubernetes.io/name=storefront").items
        return {rs.metadata.labels.get("rollouts-pod-template-hash"): rs for rs in items}

    def stable_service_hash(self) -> str | None:
        svc = self.core.read_namespaced_service("storefront-stable", NS)
        return (svc.spec.selector or {}).get("rollouts-pod-template-hash")

    def latest_analysis(self, pod_hash: str) -> dict | None:
        runs = self.co.list_namespaced_custom_object(
            "argoproj.io", "v1alpha1", NS, "analysisruns",
            label_selector=f"rollouts-pod-template-hash={pod_hash}",
        )["items"]
        if not runs:
            return None
        runs.sort(key=lambda r: r["metadata"]["creationTimestamp"])
        return runs[-1]

    def loadgen_window(self, start: float, end: float) -> dict:
        pods = self.core.list_namespaced_pod(NS, label_selector="app.kubernetes.io/name=loadgen").items
        if not pods:
            return {"requests": 0, "failed": 0}
        since = max(1, int(now() - start) + 5)
        text = self.core.read_namespaced_pod_log(pods[0].metadata.name, NS, since_seconds=since, timestamps=True)
        total = failed = 0
        for line in text.splitlines():
            stamp, _, code = line.partition(" ")
            try:
                ts = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
            if start <= ts <= end:
                total += 1
                failed += code.strip() != "200"
        return {"requests": total, "failed": failed}


def release_doc(rel: dict) -> str:
    return "# Current release. CI and the canary experiments change only this file.\n" + yaml.safe_dump(
        {"release": rel}, sort_keys=False
    )


def wait_healthy(cl: Cluster, timeout: float = 240) -> dict:
    """Rollout Healthy, not aborted, stable == current, stable fully available."""
    deadline = now() + timeout
    while now() < deadline:
        ro = cl.rollout()
        st = ro.get("status", {})
        cur, stable = st.get("currentPodHash"), st.get("stableRS")
        if st.get("phase") == "Healthy" and not st.get("abort") and cur and cur == stable:
            rs = cl.replicasets().get(stable)
            want = ro["spec"]["replicas"]
            others = [r for h, r in cl.replicasets().items() if h != stable and (r.status.replicas or 0) > 0]
            if rs and (rs.status.available_replicas or 0) >= want and not others:
                return st
        time.sleep(0.5)
    raise TimeoutError("rollout did not return to Healthy")


def run_trial(cl: Cluster, git: LabGit, kind: str, release: dict, timeout: float) -> dict:
    before = cl.rollout()
    stable = before["status"]["stableRS"]
    want = before["spec"]["replicas"]
    git.write(RELEASE_FILE, release_doc(release))
    sha, t_push = git.commit_and_push(f"release {release['id']}")

    rec: dict = {"kind": kind, "release": release["id"], "commit": sha, "stable_before": stable}
    t_detect = t_abort = t_done = t_isolated = None
    new_hash = None
    outcome = "timeout"
    while now() - t_push < timeout:
        ro = cl.rollout()
        st = ro.get("status", {})
        cur = st.get("currentPodHash")
        t = now()
        if t_detect is None and cur and cur != stable:
            t_detect, new_hash = t, cur
        if t_detect is None:
            time.sleep(0.2)
            continue
        if kind == "good":
            if st.get("abort") or st.get("phase") == "Degraded":
                outcome, t_done = "false-abort", t
                rec["message"] = st.get("message")
                break
            if st.get("stableRS") == new_hash and st.get("phase") == "Healthy":
                outcome, t_done = "promoted", t
                break
        else:
            if st.get("stableRS") == new_hash:
                outcome, t_done = "escaped", t  # bad release promoted: guardrail failure
                break
            if t_abort is None and (st.get("abort") or st.get("phase") == "Degraded"):
                t_abort = t
                rec["abort_message"] = st.get("message")
            if t_abort is not None:
                rss = cl.replicasets()
                canary, stable_rs = rss.get(new_hash), rss.get(stable)
                canary_gone = canary is None or ((canary.spec.replicas or 0) == 0 and (canary.status.replicas or 0) == 0)
                if canary_gone and t_isolated is None:
                    t_isolated = t
                stable_full = stable_rs is not None and (stable_rs.status.available_replicas or 0) >= want
                if canary_gone and stable_full and st.get("stableRS") == stable and cl.stable_service_hash() == stable:
                    outcome, t_done = "recovered", t
                    break
        time.sleep(0.2)

    rec["outcome"] = outcome
    rec["new_hash"] = new_hash
    if t_detect:
        rec["git_to_rollout_s"] = round(t_detect - t_push, 2)
    if t_done and t_detect:
        rec["seconds"] = round(t_done - t_detect, 2)          # rollout start -> recovered/promoted
        rec["seconds_from_push"] = round(t_done - t_push, 2)
    if t_abort and t_detect:
        rec["detect_to_abort_s"] = round(t_abort - t_detect, 2)
    if t_isolated and t_detect:
        rec["canary_isolated_s"] = round(t_isolated - t_detect, 2)
    if kind != "good" and new_hash:
        run = cl.latest_analysis(new_hash)
        rec["caught_by"] = "analysis" if run and run.get("status", {}).get("phase") in ("Failed", "Error") else "progress-deadline"
        if run:
            rec["analysis_phase"] = run.get("status", {}).get("phase")
    if t_detect:
        time.sleep(2.5)  # let the last loadgen lines (2s client timeout) land
        rec["client"] = cl.loadgen_window(t_detect, t_done or now())
    return rec


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default="local")
    ap.add_argument("--per-mode", type=int, default=10, help="bad releases per fault mode")
    ap.add_argument("--good", type=int, default=10, help="good releases interleaved")
    ap.add_argument("--modes", default=",".join(FAULTS), help="comma-separated fault modes")
    ap.add_argument("--timeout", type=float, default=180)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    modes = [m for m in args.modes.split(",") if m]
    plan = [m for m in modes for _ in range(args.per_mode)] + ["good"] * args.good
    random.Random(args.seed).shuffle(plan)

    cl = Cluster()
    started = dt.datetime.now(dt.timezone.utc)
    trials: list[dict] = []
    with port_forward("lab-git", "svc/lab-git", 3000) as port:
        git = LabGit(port)
        last_good = yaml.safe_load((git.repo / RELEASE_FILE).read_text())["release"]
        wait_healthy(cl)
        for i, kind in enumerate(plan, 1):
            if kind == "good":
                tag = GOOD_TAGS[i % 2] if last_good["tag"] != GOOD_TAGS[i % 2] else GOOD_TAGS[(i + 1) % 2]
                rel = {"id": f"r{i}-good", "tag": tag, "message": f"storefront r{i}", "args": [], "command": []}
            else:
                rel = {"id": f"r{i}-{kind}", "tag": last_good["tag"], "message": f"storefront r{i}",
                       "args": [], "command": []}
                rel.update(FAULTS[kind])
            rec = run_trial(cl, git, kind, rel, args.timeout)
            rec["trial"] = i
            trials.append(rec)
            log(f"{i:3d}/{len(plan)} {kind:17s} {rec['outcome']:12s} "
                f"{rec.get('seconds', '-')!s:>6}s  caught_by={rec.get('caught_by', '-')}  "
                f"client_failed={rec.get('client', {}).get('failed', '-')}/{rec.get('client', {}).get('requests', '-')}")
            if kind == "good" and rec["outcome"] == "promoted":
                last_good = rel
            else:
                # Put Git back on the last good release (the rollback a human
                # would follow up with) and wait for a clean Healthy state.
                git.write(RELEASE_FILE, release_doc(last_good))
                git.commit_and_push(f"revert to {last_good['id']}")
                wait_healthy(cl)

    bad = [t for t in trials if t["kind"] != "good"]
    good = [t for t in trials if t["kind"] == "good"]
    summary = {
        "env": args.env,
        "started": started.isoformat(),
        "bad_releases": len(bad),
        "recovered": sum(t["outcome"] == "recovered" for t in bad),
        "escaped": sum(t["outcome"] == "escaped" for t in bad),
        "bad_timeouts": sum(t["outcome"] == "timeout" for t in bad),
        "recovery_seconds": summarize([t["seconds"] for t in bad if t["outcome"] == "recovered"]),
        "canary_isolated_seconds": summarize([t["canary_isolated_s"] for t in bad if "canary_isolated_s" in t]),
        "recovery_seconds_from_push": summarize([t["seconds_from_push"] for t in bad if t["outcome"] == "recovered"]),
        "by_mode": {
            m: {
                "recovered": sum(t["outcome"] == "recovered" for t in bad if t["kind"] == m),
                "n": sum(t["kind"] == m for t in bad),
                "seconds": summarize([t["seconds"] for t in bad if t["kind"] == m and t["outcome"] == "recovered"]),
                "caught_by": sorted({t.get("caught_by", "-") for t in bad if t["kind"] == m}),
            }
            for m in modes
        },
        "good_releases": len(good),
        "promoted": sum(t["outcome"] == "promoted" for t in good),
        "false_aborts": sum(t["outcome"] == "false-abort" for t in good),
        "promotion_seconds": summarize([t["seconds"] for t in good if t["outcome"] == "promoted"]),
        "git_to_rollout_seconds": summarize([t["git_to_rollout_s"] for t in trials if "git_to_rollout_s" in t]),
        "client_requests_during_bad_releases": sum(t.get("client", {}).get("requests", 0) for t in bad),
        "client_failed_during_bad_releases": sum(t.get("client", {}).get("failed", 0) for t in bad),
    }
    stamp = started.strftime("%Y%m%dT%H%M%SZ")
    write_json(RESULTS / args.env / f"rollouts-{stamp}.json", {"summary": summary, "trials": trials})
    print(yaml.safe_dump(summary, sort_keys=False))


if __name__ == "__main__":
    main()
