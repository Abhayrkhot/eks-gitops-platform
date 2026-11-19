#!/usr/bin/env bash
# Every local measurement in one go, against the lab from `make local-up`:
# failed releases, drift repair (tuned and upstream-default self-heal
# backoff), and the policy gate. Results land in results/local/.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."

export KUBECONFIG="$HOME/.kube/egp-gitops.yaml"
UV=(uv run -q --with-requirements experiments/requirements.txt)
PER_MODE="${PER_MODE:-10}"
mkdir -p .work

say() { echo; echo "=== [$(date -u +%T)] $*"; }

say "failed releases: $PER_MODE per fault mode x 7 modes + $PER_MODE good"
"${UV[@]}" experiments/rollouts/run.py --env local --per-mode "$PER_MODE" --good "$PER_MODE"

say "drift repair, tuned backoff"
"${UV[@]}" experiments/drift/run.py --env local --rounds 6 --single 30 --tag tuned

say "drift repair, upstream default backoff"
cat > .work/argocd-defaults.tfvars.json <<'EOF'
{"argocd_values": {"configs": {"params": {
  "controller.self.heal.backoff.timeout.seconds": "2",
  "controller.self.heal.backoff.factor": "3",
  "controller.self.heal.backoff.cap.seconds": "300"}}}}
EOF
make local-gitops GITOPS_ARGS="-var-file=$PWD/.work/argocd-defaults.tfvars.json"
make wait
"${UV[@]}" experiments/drift/run.py --env local --rounds 6 --single 30 --tag defaults
make local-gitops   # back to the tuned values
make wait

say "policy gate"
"${UV[@]}" experiments/policy/run.py --env local --workers 6

python3 scripts/results-table.py
say "done"
