#!/usr/bin/env bash
# Manage the in-cluster lab Git server (Gitea) that Argo CD reconciles from in
# local runs and canary experiments.
#
#   lab/lab-git.sh deploy   install Gitea, create the lab admin, wait until ready
#   lab/lab-git.sh seed     snapshot this working tree and push it to lab/eks-gitops-platform
#   lab/lab-git.sh hook     register the push webhook that refreshes Argo CD
#   lab/lab-git.sh url      print the in-cluster clone URL
#
# Uses the current kubectl context. The admin password is random per cluster,
# kept in .work/lab-git.pass and the lab-git/lab-git-admin Secret.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.work"
REPO_DIR="$WORK/lab-repo"
PASS_FILE="$WORK/lab-git.pass"
NS=lab-git
USER_NAME=lab
REPO=eks-gitops-platform
LOCAL_PORT="${LAB_GIT_PORT:-13000}"
CLONE_URL="http://lab-git.lab-git.svc.cluster.local:3000/${USER_NAME}/${REPO}.git"
mkdir -p "$WORK"

pf_pid=""
port_forward() {
  kubectl -n "$NS" port-forward svc/lab-git "${LOCAL_PORT}:3000" >/dev/null 2>&1 &
  pf_pid=$!
  trap '[[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null || true' EXIT
  for _ in $(seq 1 50); do
    curl -sf -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/api/healthz" && return 0
    sleep 0.2
  done
  echo "port-forward to lab-git failed" >&2
  return 1
}

auth_header() {
  printf 'Authorization: Basic %s' "$(printf '%s:%s' "$USER_NAME" "$(cat "$PASS_FILE")" | base64 -w0)"
}

cmd_deploy() {
  kubectl apply -f "$ROOT/lab/lab-git.yaml" >/dev/null
  kubectl -n "$NS" rollout status deploy/lab-git --timeout=180s >/dev/null
  if ! kubectl -n "$NS" get secret lab-git-admin >/dev/null 2>&1; then
    openssl rand -hex 16 >"$PASS_FILE"
    kubectl -n "$NS" exec deploy/lab-git -- gitea admin user create \
      --username "$USER_NAME" --password "$(cat "$PASS_FILE")" \
      --email lab@lab.invalid --admin --must-change-password=false >/dev/null
    kubectl -n "$NS" create secret generic lab-git-admin \
      --from-literal=username="$USER_NAME" --from-file=password="$PASS_FILE" >/dev/null
  else
    kubectl -n "$NS" get secret lab-git-admin -o jsonpath='{.data.password}' | base64 -d >"$PASS_FILE"
  fi
  echo "lab-git ready: $CLONE_URL"
}

cmd_seed() {
  local src_rev
  src_rev="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo worktree)"
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    git init -q -b main "$REPO_DIR"
    git -C "$REPO_DIR" config user.name "lab"
    git -C "$REPO_DIR" config user.email "lab@lab.invalid"
    git -C "$REPO_DIR" config commit.gpgsign false
  fi
  rsync -a --delete \
    --exclude .git/ --exclude .terraform/ --exclude .work/ --exclude results/ \
    --exclude '*.tfstate*' --exclude '__pycache__/' \
    "$ROOT/" "$REPO_DIR/"
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q --allow-empty -m "snapshot of ${src_rev} at $(date -u +%FT%TZ)"
  port_forward
  git -C "$REPO_DIR" -c http.extraHeader="$(auth_header)" \
    push -q -f "http://127.0.0.1:${LOCAL_PORT}/${USER_NAME}/${REPO}.git" main
  echo "seeded lab-git main at $(git -C "$REPO_DIR" rev-parse --short HEAD)"
}

cmd_hook() {
  port_forward
  local api="http://127.0.0.1:${LOCAL_PORT}/api/v1/repos/${USER_NAME}/${REPO}/hooks"
  if curl -sf -H "$(auth_header)" "$api" | grep -q 'argocd-server'; then
    echo "webhook already registered"; return 0
  fi
  curl -sf -H "$(auth_header)" -H 'Content-Type: application/json' -X POST "$api" -d '{
      "type": "gogs",
      "active": true,
      "events": ["push"],
      "config": {"url": "http://argocd-server.argocd.svc.cluster.local/api/webhook", "content_type": "json"}
    }' >/dev/null
  echo "webhook registered -> argocd-server /api/webhook"
}

case "${1:-}" in
  deploy) cmd_deploy ;;
  seed) cmd_seed ;;
  hook) cmd_hook ;;
  url) echo "$CLONE_URL" ;;
  *) echo "usage: $0 deploy|seed|hook|url" >&2; exit 2 ;;
esac
