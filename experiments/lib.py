"""Shared helpers for the experiment harnesses (drift, rollouts).

Run through uv so the dependencies are pinned, e.g.:
    uv run --with-requirements experiments/requirements.txt experiments/rollouts/run.py
"""

from __future__ import annotations

import base64
import contextlib
import json
import os
import pathlib
import socket
import statistics
import subprocess
import sys
import time
from typing import Iterator

from kubernetes import client, config

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK = ROOT / ".work"
RESULTS = ROOT / "results"


def kube() -> tuple[client.ApiClient, client.CoreV1Api, client.AppsV1Api, client.CustomObjectsApi]:
    config.load_kube_config(config_file=os.environ.get("KUBECONFIG"))
    api = client.ApiClient()
    return api, client.CoreV1Api(api), client.AppsV1Api(api), client.CustomObjectsApi(api)


def now() -> float:
    return time.time()


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def percentile(values: list[float], pct: float) -> float:
    """Nearest-rank percentile (no interpolation), so p100 == max."""
    if not values:
        return float("nan")
    ordered = sorted(values)
    rank = max(1, min(len(ordered), int(round(pct / 100.0 * len(ordered) + 0.5))))
    return ordered[rank - 1]


def summarize(values: list[float]) -> dict:
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "min": round(min(values), 2),
        "p50": round(statistics.median(values), 2),
        "p95": round(percentile(values, 95), 2),
        "max": round(max(values), 2),
        "mean": round(statistics.fmean(values), 2),
    }


def write_json(path: pathlib.Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    log(f"wrote {path.relative_to(ROOT)}")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def port_forward(namespace: str, target: str, remote_port: int) -> Iterator[int]:
    port = free_port()
    proc = subprocess.Popen(
        ["kubectl", "-n", namespace, "port-forward", target, f"{port}:{remote_port}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.time() + 15
        while time.time() < deadline:
            with contextlib.suppress(OSError), socket.create_connection(("127.0.0.1", port), timeout=0.5):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"port-forward to {namespace}/{target} did not come up")
        yield port
    finally:
        proc.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=5)


class LabGit:
    """Commits to the snapshot clone in .work/lab-repo and pushes to lab-git."""

    def __init__(self, port: int):
        self.repo = WORK / "lab-repo"
        if not (self.repo / ".git").exists():
            sys.exit("lab repo missing: run `lab/lab-git.sh seed` first")
        password = (WORK / "lab-git.pass").read_text().strip()
        token = base64.b64encode(f"lab:{password}".encode()).decode()
        self.header = f"Authorization: Basic {token}"
        self.remote = f"http://127.0.0.1:{port}/lab/eks-gitops-platform.git"

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True
        ).stdout.strip()

    def write(self, rel_path: str, content: str) -> None:
        (self.repo / rel_path).write_text(content)

    def commit_and_push(self, message: str) -> tuple[str, float]:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        sha = self.git("rev-parse", "--short", "HEAD")
        self.git("-c", f"http.extraHeader={self.header}", "push", "-q", self.remote, "HEAD:main")
        return sha, now()
