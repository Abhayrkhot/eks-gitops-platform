#!/usr/bin/env python3
"""Render docs/results.md from the newest result files in results/<env>/.

Every number in the results doc comes from a JSON file written by an
experiment harness; nothing is typed in by hand.

    python3 scripts/results-table.py            # writes docs/results.md
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
ENV_TITLES = {"dev": "Real AWS (EKS, us-east-2)", "local": "Local lab (kind + moto)", "ci": "GitHub Actions (kind + moto)"}


def newest(env: str, prefix: str, tag: str | None = None) -> tuple[Path, dict] | None:
    files = sorted((RESULTS / env).glob(f"{prefix}-2*.json"))
    if tag is not None:
        files = [f for f in files if f.stem.endswith(f"-{tag}")]
    else:
        files = [f for f in files if f.stem.count("-") == prefix.count("-") + 1]
    if not files:
        return None
    return files[-1], json.loads(files[-1].read_text())


def s(stat: dict, key: str = "p50", unit: str = "s") -> str:
    if not stat or not stat.get("n"):
        return "-"
    return f"{stat[key]}{unit}"


def rel(p: Path) -> str:
    return f"[`{p.relative_to(ROOT)}`](../{p.relative_to(ROOT)})"


def rollouts(env: str) -> list[str]:
    got = newest(env, "rollouts")
    if not got:
        return []
    path, doc = got
    sm = doc["summary"]
    out = [f"### Failed releases rolled back automatically ({rel(path)})", "",
           f"- **{sm['recovered']}/{sm['bad_releases']} bad releases recovered**, {sm['escaped']} escaped, "
           f"{sm['bad_timeouts']} timed out.",
           f"- Recovery (canary created -> canary gone and stable back at full capacity): "
           f"median **{s(sm['recovery_seconds'])}**, p95 {s(sm['recovery_seconds'], 'p95')}, "
           f"max **{s(sm['recovery_seconds'], 'max')}**.",
           f"- Canary isolated (no client traffic can reach the bad version): median "
           f"{s(sm.get('canary_isolated_seconds', {}))}, max {s(sm.get('canary_isolated_seconds', {}), 'max')}.",
           f"- Git push -> rollout started (webhook + sync): median {s(sm['git_to_rollout_seconds'])}.",
           f"- Good releases: {sm['promoted']}/{sm['good_releases']} promoted, {sm['false_aborts']} false aborts, "
           f"median promotion {s(sm['promotion_seconds'])}.",
           f"- Client traffic during bad releases: {sm['client_failed_during_bad_releases']} failed of "
           f"{sm['client_requests_during_bad_releases']} requests "
           f"({100 * sm['client_failed_during_bad_releases'] / max(1, sm['client_requests_during_bad_releases']):.2f}%).",
           "", "| Fault | Recovered | Caught by | Median | Max |", "|---|---|---|---|---|"]
    for mode, m in sm["by_mode"].items():
        out.append(f"| {mode} | {m['recovered']}/{m['n']} | {', '.join(m['caught_by'])} | "
                   f"{s(m['seconds'])} | {s(m['seconds'], 'max')} |")
    return out + [""]


def drift(env: str) -> list[str]:
    out = []
    for tag, label in (("tuned", "tuned self-heal backoff (1s x2, cap 10s)"), ("defaults", "Argo CD default backoff (2s x3, cap 300s)")):
        got = newest(env, "drift", tag)
        if not got:
            continue
        path, doc = got
        sm = doc["summary"]
        out += [f"### Drift repair, {label} ({rel(path)})", "",
                f"- {sm['managed_resources']} managed resources ({len(sm['kinds'])} kinds, {len(sm['apps'])} apps), "
                f"all drifted at once in each of {sm['rounds']} rounds: "
                f"**{sm['resources_restored_total']}/{sm['resources_drifted_total']} restored**.",
                f"- Every resource restored: median **{s(sm['all_restored_seconds'])}**, "
                f"max **{s(sm['all_restored_seconds'], 'max')}**; every app Synced+Healthy again: "
                f"median {s(sm['apps_synced_healthy_seconds'])}, max {s(sm['apps_synced_healthy_seconds'], 'max')}.",
                f"- Per resource: median {s(sm['per_resource_seconds'])}, p95 {s(sm['per_resource_seconds'], 'p95')}.",
                f"- One resource at a time ({sm['single_drift_seconds'].get('n', 0)} trials): median "
                f"{s(sm['single_drift_seconds'])}, p95 {s(sm['single_drift_seconds'], 'p95')}, "
                f"max {s(sm['single_drift_seconds'], 'max')}.", ""]
        out += ["| Round | Mode | Restored | All restored | Apps healthy |", "|---|---|---|---|---|"]
        for i, r in enumerate(doc["rounds"], 1):
            out.append(f"| {i} | {r['mode']} | {r['restored']}/{r['drifted']} | {r['all_restored_seconds']}s | "
                       f"{r['apps_synced_healthy_seconds']}s |")
        out.append("")
    return out


def policy(env: str) -> list[str]:
    got = newest(env, "policy")
    if not got:
        return []
    path, doc = got
    sm = doc["summary"]
    out = [f"### Plan-time policy gate ({rel(path)})", "",
           f"- **{sm['blocked']}/{sm['unsafe_changes']} unsafe pull requests blocked** by real `terraform plan` + conftest; "
           f"missed: {sm['missed'] or 'none'}.",
           f"- {sm['passed']}/{sm['safe_changes']} safe changes (incl. no-change baselines) passed; "
           f"false positives: {sm['false_positives'] or 'none'}.",
           f"- Rules exercised: {len(sm['rules_exercised'])} ({', '.join(sm['rules_exercised'])}).",
           f"- Plan + policy per fixture: median {s(sm['seconds_per_fixture'])}."]
    if sm.get("skipped_needs_aws"):
        out.append(f"- Skipped here (needs real EKS add-ons): {', '.join(sm['skipped_needs_aws'])}.")
    out += ["", "| Fixture | Change | Expected | Fired | Verdict |", "|---|---|---|---|---|"]
    for f in doc["fixtures"]:
        out.append(f"| {f['id']} | {f['name']} | {', '.join(f['expect']) or '-'} | "
                   f"{', '.join(f.get('found', [])) or '-'} | {f['verdict']} |")
    return out + [""]


def iam(env: str) -> list[str]:
    got = newest(env, "iam")
    if not got:
        return []
    path, doc = got
    sm = doc["summary"]
    checks = doc["checks"]
    simulated = [c["id"] for c in checks if c.get("simulated")]
    live = sm["denied"] - len(simulated)
    out = [f"### IAM guardrails enforced by AWS ({rel(path)})", "",
           f"- **{sm['denied']}/{sm['unsafe_calls']} unsafe API calls denied** for the CI roles "
           f"(allowed by mistake: {sm['unsafe_allowed'] or 'none'}; denied only by the account's own SCP, so not counted: "
           f"{sm.get('not_credited') or 'none'})."]
    if simulated:
        out.append(f"- {live} were denied live by the CI roles' own policies or permissions boundary. "
                   f"{len(simulated)} ({', '.join(simulated)}) were decided by the IAM policy simulator against the "
                   "same role policies and boundary, because the live call could not show it: the service rejected the "
                   "test target before authorizing, or the denial message names no policy.")
    out.append(f"- {sm['controls_allowed']}/{sm['controls']} control calls still allowed (broken: {sm['controls_broken'] or 'none'}).")
    blocked_controls = [c for c in checks if c["expected"] == "allowed" and c["decision"] == "denied"]
    for c in blocked_controls:
        out.append(f"- {c['id']} was denied by {'the account’s AWS Organizations SCP, not by this project' if c.get('denied_by') == 'scp' else c.get('denied_by') or 'AWS'}.")
    out += ["", "| Check | Role | Attempt | Expected | Got | Denied by |", "|---|---|---|---|---|---|"]
    for c in checks:
        by = f"policy simulator: {c['simulated']}" if c.get("simulated") else (c.get("denied_by") or "-")
        out.append(f"| {c['id']} | {c['role']} | {c['check']} | {c['expected']} | {c['decision']} ({c['detail']}) | {by} |")
    return out + [""]


def provisioning(env: str) -> list[str]:
    out = []
    for prefix, label in (("provisioning", "Terraform modules + GitOps"), ("provisioning-baseline", "sequential CLI runbook (baseline)")):
        got = newest(env, prefix)
        if not got:
            continue
        path, doc = got
        sm = doc["summary"]
        out += [f"### Provisioning: {label} ({rel(path)})", "",
                f"- Empty account -> every app Synced+Healthy: median **{s(sm['platform_ready_minutes'], 'p50', ' min')}**, "
                f"min {s(sm['platform_ready_minutes'], 'min', ' min')}, max {s(sm['platform_ready_minutes'], 'max', ' min')} "
                f"over {sm['cycles']} cycles; teardown median {s(sm['teardown_minutes'], 'p50', ' min')}."]
        for phase in ("infra_seconds", "access_seconds", "gitops_seconds", "converge_seconds"):
            if phase in sm and prefix == "provisioning":
                out.append(f"- {phase.split('_')[0]}: median {s(sm[phase])}")
        for name, st in sm.get("steps_seconds", {}).items():
            out.append(f"- {name}: median {s(st)}")
        out.append("")
    tf, base = newest(env, "provisioning"), newest(env, "provisioning-baseline")
    if tf and base and "platform_seconds" in base[1]["summary"]:
        t, b = dict(tf[1]["summary"]), dict(base[1]["summary"])
        if "platform_seconds" not in t:  # older Terraform runs: same grouping, from the per-cycle phases
            vals = [c["access_s"] + c["gitops_s"] + c["converge_s"] for c in tf[1]["cycles"]]
            t["platform_seconds"] = {"min": min(vals), "p50": statistics.median(vals), "max": max(vals)}

        def row(label: str, key: str, unit: float = 60.0, suffix: str = " min") -> str:
            tv, bv = t[key], b[key]
            delta = (bv["p50"] - tv["p50"]) / bv["p50"] * 100 if bv.get("p50") else 0
            return (f"| {label} | {tv['p50'] / unit:.1f}{suffix} ({tv['min'] / unit:.1f}–{tv['max'] / unit:.1f}) | "
                    f"{bv['p50'] / unit:.1f}{suffix} ({bv['min'] / unit:.1f}–{bv['max'] / unit:.1f}) | {delta:+.0f}% |")

        ready = {k: {q: v * 60 for q, v in sm_["platform_ready_minutes"].items() if q != "n"}
                 for k, sm_ in (("t", t), ("b", b))}
        t["ready_seconds"], b["ready_seconds"] = ready["t"], ready["b"]
        out += ["### Provisioning comparison (median, range)", "",
                f"Terraform modules + GitOps: {t['cycles']} cycles. AWS getting-started CLI steps, scripted: "
                f"{b['cycles']} cycles. Same region, Kubernetes version, instance type, node count, charts and Git source.",
                "", "| Phase | Terraform + GitOps | CLI runbook | Time saved |", "|---|---|---|---|",
                row("AWS resources (VPC, IAM, EKS, nodes)", "infra_seconds"),
                row("Argo CD + every app Synced+Healthy", "platform_seconds"),
                row("**Empty account to platform ready**", "ready_seconds"), ""]
    return out


def main() -> None:
    lines = ["# Results", "",
             "Generated by `scripts/results-table.py` from the newest JSON in `results/<env>/`. "
             "Rerun the experiments, then this script, to refresh.", ""]
    for env in ("dev", "local", "ci"):
        body = provisioning(env) + rollouts(env) + drift(env) + policy(env) + iam(env)
        if body:
            lines += [f"## {ENV_TITLES.get(env, env)}", ""] + body
    out = ROOT / "docs" / "results.md"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(lines).rstrip() + "\n")
    print(f"wrote {out.relative_to(ROOT)}", file=sys.stderr)


if __name__ == "__main__":
    main()
