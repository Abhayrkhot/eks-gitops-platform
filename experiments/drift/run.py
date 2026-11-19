#!/usr/bin/env python3
"""Drift-repair experiment: how fast does Argo CD self-heal undo out-of-band changes?

The harness reads the managed resources of the storefront and tenant
Applications from Argo CD itself, then drifts them the way people do in real
clusters: `kubectl edit` on a field Git owns (scale a Deployment, widen a
quota, weaken a NetworkPolicy, add a verb to a Role, flip a namespace's Pod
Security level, loosen the canary's failureLimit, ...) or `kubectl delete`.
Each mutation is a server-side API call; all of a round's mutations are
fired in parallel.

A resource counts as restored when the live object matches what Git renders
again (for deletions: the object exists again with a new UID and the same
spec). The round ends when every resource is restored and every Application
is back to Synced/Healthy.

    KUBECONFIG=~/.kube/egp-gitops.yaml uv run --with-requirements experiments/requirements.txt \
        experiments/drift/run.py --env local --rounds 6
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import copy
import datetime as dt
import random
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml
from kubernetes.client.exceptions import ApiException
from kubernetes.dynamic import DynamicClient
from kubernetes.dynamic.exceptions import NotFoundError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib import RESULTS, kube, log, now, summarize, write_json  # noqa: E402

APP_PREFIXES = ("storefront", "tenant-")
JSON_PATCH = "application/json-patch+json"
MERGE_PATCH = "application/merge-patch+json"


@dataclass
class Target:
    app: str
    api_version: str
    kind: str
    namespace: str | None
    name: str
    mutation: str = ""
    expected: object = None
    old_uid: str = ""
    injected_at: float = 0.0
    restored_at: float | None = None
    error: str | None = None
    extra: dict = field(default_factory=dict)

    @property
    def key(self) -> str:
        ns = f"{self.namespace}/" if self.namespace else ""
        return f"{self.kind}/{ns}{self.name}"


# ---------------------------------------------------------------- mutations
# Each entry: kind -> (description, projection(obj) -> comparable, patch builder)
def proj_spec(field_name):
    return lambda o: copy.deepcopy((o.get("spec") or {}).get(field_name))


MODIFY = {
    "Deployment": ("scale replicas to 3", proj_spec("replicas"),
                   lambda o: (MERGE_PATCH, {"spec": {"replicas": 3}})),
    "Rollout": ("scale replicas to 2", proj_spec("replicas"),
                lambda o: (MERGE_PATCH, {"spec": {"replicas": 2}})),
    # targetPort, not port: `port` is the merge key of the ports list, so a
    # client-side apply adds the Git entry next to the drifted one and the API
    # rejects the duplicate port name (see docs/design.md, known limits).
    "Service": ("send traffic to the wrong container port (targetPort 8080)",
                lambda o: [p.get("targetPort") for p in o["spec"]["ports"]],
                lambda o: (JSON_PATCH, [{"op": "replace", "path": "/spec/ports/0/targetPort", "value": 8080}])),
    "ConfigMap": ("overwrite a key", lambda o: copy.deepcopy(o.get("data")),
                  lambda o: (MERGE_PATCH, {"data": {sorted(o["data"])[0]: "drifted"}})),
    "ResourceQuota": ("raise pod quota to 999", proj_spec("hard"),
                      lambda o: (MERGE_PATCH, {"spec": {"hard": {"pods": "999"}}})),
    "LimitRange": ("raise max memory to 4Gi", proj_spec("limits"),
                   lambda o: (JSON_PATCH, [{"op": "replace", "path": "/spec/limits/0/max/memory", "value": "4Gi"}])),
    # Argo CD's three-way diff ignores fields Git never set, so every mutation
    # changes a field the chart does set (here: drop the egress/ingress rule type).
    "NetworkPolicy": ("drop a policy type (egress or ingress no longer enforced)", proj_spec("policyTypes"),
                      lambda o: (MERGE_PATCH, {"spec": {"policyTypes":
                                 ["Ingress"] if "Egress" in o["spec"].get("policyTypes", []) else ["Egress"]}})),
    "Role": ("add the delete verb", lambda o: copy.deepcopy(o.get("rules")),
             lambda o: (JSON_PATCH, [{"op": "add", "path": "/rules/0/verbs/-", "value": "delete"}])),
    "RoleBinding": ("bind an extra user", lambda o: copy.deepcopy(o.get("subjects")),
                    lambda o: (JSON_PATCH, [{"op": "add", "path": "/subjects/-",
                                             "value": {"apiGroup": "rbac.authorization.k8s.io", "kind": "User", "name": "intruder"}}])),
    "ServiceAccount": ("enable token automount", lambda o: o.get("automountServiceAccountToken"),
                       lambda o: (MERGE_PATCH, {"automountServiceAccountToken": True})),
    "Namespace": ("downgrade Pod Security to privileged",
                  lambda o: (o["metadata"].get("labels") or {}).get("pod-security.kubernetes.io/enforce"),
                  lambda o: (MERGE_PATCH, {"metadata": {"labels": {"pod-security.kubernetes.io/enforce": "privileged"}}})),
    "PodDisruptionBudget": ("allow 5 unavailable", proj_spec("maxUnavailable"),
                            lambda o: (MERGE_PATCH, {"spec": {"maxUnavailable": 5}})),
    "AnalysisTemplate": ("loosen failureLimit to 10", lambda o: o["spec"]["metrics"][0].get("failureLimit"),
                         lambda o: (JSON_PATCH, [{"op": "replace", "path": "/spec/metrics/0/failureLimit", "value": 10}])),
}

# Deleting a Namespace deletes everything in it (a different failure); its
# drift is the Pod Security label change above.
NO_DELETE = {"Namespace"}

# What "the same spec" means after a deleted object is recreated.
RECREATE_PROJECTION = {k: v[1] for k, v in MODIFY.items()}


class Harness:
    def __init__(self):
        api, self.core, self.apps, self.co = kube()
        self.dyn = DynamicClient(api)
        self._res = {}

    def res(self, api_version: str, kind: str):
        k = (api_version, kind)
        if k not in self._res:
            self._res[k] = self.dyn.resources.get(api_version=api_version, kind=kind)
        return self._res[k]

    def get(self, t: Target):
        try:
            return self.res(t.api_version, t.kind).get(name=t.name, namespace=t.namespace).to_dict()
        except NotFoundError:
            return None

    def applications(self) -> list[dict]:
        return self.co.list_namespaced_custom_object("argoproj.io", "v1alpha1", "argocd", "applications")["items"]

    def apps_ready(self) -> bool:
        apps = [a for a in self.applications() if a["metadata"]["name"].startswith(APP_PREFIXES)]
        return bool(apps) and all(
            a.get("status", {}).get("sync", {}).get("status") == "Synced"
            and a.get("status", {}).get("health", {}).get("status") == "Healthy"
            for a in apps
        )

    def wait_apps_ready(self, timeout=300) -> float | None:
        start = now()
        while now() - start < timeout:
            if self.apps_ready():
                return now()
            time.sleep(0.5)
        for a in self.applications():
            st = a.get("status", {})
            if a["metadata"]["name"].startswith(APP_PREFIXES) and (
                st.get("sync", {}).get("status") != "Synced" or st.get("health", {}).get("status") != "Healthy"
            ):
                msg = (st.get("operationState") or {}).get("message", "")
                log(f"  not ready: {a['metadata']['name']} sync={st.get('sync', {}).get('status')} "
                    f"health={st.get('health', {}).get('status')} {msg[:300]}")
        return None

    def discover(self) -> list[Target]:
        out = []
        for app in self.applications():
            name = app["metadata"]["name"]
            if not name.startswith(APP_PREFIXES):
                continue
            for r in app.get("status", {}).get("resources", []):
                if r["kind"] not in MODIFY:
                    continue
                av = f"{r['group']}/{r['version']}" if r.get("group") else r["version"]
                out.append(Target(app=name, api_version=av, kind=r["kind"], namespace=r.get("namespace") or None, name=r["name"]))
        return sorted(out, key=lambda t: (t.app, t.key))

    # ------------------------------------------------------------ inject
    def inject(self, t: Target, mode: str) -> None:
        obj = self.get(t)
        if obj is None:
            t.error = "missing before injection"
            return
        t.old_uid = obj["metadata"]["uid"]
        res = self.res(t.api_version, t.kind)
        try:
            if mode == "delete" and t.kind not in NO_DELETE:
                t.mutation = "delete"
                t.expected = RECREATE_PROJECTION[t.kind](obj)
                t.injected_at = now()
                res.delete(name=t.name, namespace=t.namespace, body={"propagationPolicy": "Background"})
            else:
                desc, projection, build = MODIFY[t.kind]
                t.mutation = desc
                t.expected = projection(obj)
                content_type, body = build(obj)
                t.injected_at = now()
                res.patch(name=t.name, namespace=t.namespace, body=body, content_type=content_type)
                # Prove the drift landed before timing the repair.
                live = self.get(t)
                if live is not None and projection(live) == t.expected:
                    t.extra["note"] = "already restored when re-read"
        except ApiException as e:
            t.error = f"{e.status} {e.reason}"

    def restored(self, t: Target) -> bool:
        obj = self.get(t)
        if obj is None:
            return False
        if t.mutation == "delete":
            if obj["metadata"]["uid"] == t.old_uid:
                return False  # still terminating, or not deleted yet
            return RECREATE_PROJECTION[t.kind](obj) == t.expected
        return MODIFY[t.kind][1](obj) == t.expected


def run_round(h: Harness, targets: list[Target], mode: str, timeout: float) -> dict:
    if h.wait_apps_ready() is None:
        raise RuntimeError("platform not Synced/Healthy before the round; timings would be meaningless")
    rng = random.Random()
    for t in targets:
        t.restored_at, t.error, t.extra = None, None, {}
    modes = {t.key: (mode if mode != "mixed" else rng.choice(["modify", "delete"])) for t in targets}

    t0 = now()
    with cf.ThreadPoolExecutor(max_workers=32) as pool:
        list(pool.map(lambda t: h.inject(t, modes[t.key]), targets))
    t_injected = now()

    pending = [t for t in targets if t.error is None]
    with cf.ThreadPoolExecutor(max_workers=16) as pool:
        while pending and now() - t0 < timeout:
            checks = list(pool.map(h.restored, pending))
            stamp = now()
            for t, ok in zip(pending, checks):
                if ok:
                    t.restored_at = stamp
            pending = [t for t in pending if t.restored_at is None]
            time.sleep(0.2)
    t_all = now()
    t_apps = h.wait_apps_ready()

    per = [t.restored_at - t.injected_at for t in targets if t.restored_at]
    unrestored = [f"{t.key} ({t.mutation})" for t in targets if t.restored_at is None and t.error is None]
    for u in unrestored:
        log(f"  NOT RESTORED: {u}")
    return {
        "mode": mode,
        "drifted": len(targets),
        "injection_errors": [t.key + ": " + t.error for t in targets if t.error],
        "restored": len(per),
        "unrestored": unrestored,
        "inject_seconds": round(t_injected - t0, 2),
        # Only meaningful when everything came back.
        "all_restored_seconds": round(max(t.restored_at for t in targets if t.restored_at) - t0, 2)
        if per and not unrestored else None,
        "apps_synced_healthy_seconds": round(t_apps - t0, 2) if t_apps else None,
        "per_resource_seconds": summarize(per),
        "kinds": sorted({t.kind for t in targets}),
        "resources": [
            {"key": t.key, "app": t.app, "mutation": t.mutation,
             "seconds": round(t.restored_at - t.injected_at, 2) if t.restored_at else None,
             "error": t.error, **t.extra}
            for t in targets
        ],
        "_timeout_hit": t_all - t0 >= timeout,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default="local")
    ap.add_argument("--rounds", type=int, default=6, help="mass-drift rounds (cycles modify, delete, mixed)")
    ap.add_argument("--single", type=int, default=0, help="extra one-resource-at-a-time trials")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--tag", default="", help="label for this configuration (e.g. tuned, defaults)")
    args = ap.parse_args()

    h = Harness()
    h.wait_apps_ready()
    targets = h.discover()
    log(f"{len(targets)} managed resources across {len({t.app for t in targets})} apps, kinds: "
        + ", ".join(sorted({t.kind for t in targets})))

    started = dt.datetime.now(dt.timezone.utc)
    rounds, singles = [], []
    aborted = None
    try:
        cycle = ["modify", "delete", "mixed"]
        for i in range(args.rounds):
            mode = cycle[i % len(cycle)]
            r = run_round(h, targets, mode, args.timeout)
            rounds.append(r)
            log(f"round {i + 1}/{args.rounds} {mode:6s}: {r['restored']}/{r['drifted']} restored, "
                f"all in {r['all_restored_seconds']}s, apps healthy in {r['apps_synced_healthy_seconds']}s, "
                f"per-resource p50 {r['per_resource_seconds'].get('p50')}s")
            time.sleep(5)

        rng = random.Random(11)
        for _ in range(args.single):
            t = copy.copy(rng.choice(targets))
            r = run_round(h, [t], rng.choice(["modify", "delete"]) if t.kind not in NO_DELETE else "modify", 120)
            singles.append(r["resources"][0])
            time.sleep(3)
        if singles:
            log(f"single drifts: {summarize([s['seconds'] for s in singles if s['seconds'] is not None])}")
    except RuntimeError as e:
        # Keep the partial results: a round that never healed is the finding.
        aborted = str(e)
        log(f"ABORTED: {aborted}")

    summary = {
        "env": args.env,
        "tag": args.tag,
        "started": started.isoformat(),
        "aborted": aborted,
        "managed_resources": len(targets),
        "apps": sorted({t.app for t in targets}),
        "kinds": sorted({t.kind for t in targets}),
        "rounds": len(rounds),
        "resources_drifted_total": sum(r["drifted"] for r in rounds),
        "resources_restored_total": sum(r["restored"] for r in rounds),
        "unrestored": [u for r in rounds for u in r["unrestored"]],
        "all_restored_seconds": summarize([r["all_restored_seconds"] for r in rounds if r["all_restored_seconds"]]),
        "apps_synced_healthy_seconds": summarize([r["apps_synced_healthy_seconds"] for r in rounds
                                                  if r["apps_synced_healthy_seconds"]]),
        "per_resource_seconds": summarize([x["seconds"] for r in rounds for x in r["resources"] if x["seconds"] is not None]),
        "single_drift_seconds": summarize([s["seconds"] for s in singles if s["seconds"] is not None]),
    }
    stamp = started.strftime("%Y%m%dT%H%M%SZ")
    suffix = f"-{args.tag}" if args.tag else ""
    write_json(RESULTS / args.env / f"drift-{stamp}{suffix}.json", {"summary": summary, "rounds": rounds, "singles": singles})
    print(yaml.safe_dump(summary, sort_keys=False))
    sys.exit(1 if aborted or summary["unrestored"] else 0)


if __name__ == "__main__":
    main()
