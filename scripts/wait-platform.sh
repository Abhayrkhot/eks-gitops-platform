#!/usr/bin/env bash
# Wait until every Argo CD Application is Synced + Healthy (and the expected
# set exists), then print how long it took. Exit 1 on timeout.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

TIMEOUT="${TIMEOUT:-900}"
EXPECTED="${EXPECTED_APPS:-10}"   # root + 2 add-ons + storefront + 6 tenants
start=$(date +%s)

while true; do
  now=$(date +%s)
  elapsed=$((now - start))
  apps=$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null || echo '{"items":[]}')
  total=$(jq '.items | length' <<<"$apps")
  ready=$(jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy")] | length' <<<"$apps")
  # Timeline: one line whenever any app's sync/health state changes, so slow convergence can be attributed.
  # Apps not yet Synced+Healthy also carry their first condition / operation message (why they wait).
  state=$(jq -r '[.items[] | "\(.metadata.name)=\(.status.sync.status // "-")/\(.status.health.status // "-")"
      + (if (.status.sync.status == "Synced" and .status.health.status == "Healthy") then "" else
          ([(.status.conditions // [])[0] | select(.) | "\(.type): \(.message)"]
           + [.status.operationState | select(. and .phase != "Succeeded") | "op \(.phase): \(.message // "")"]
           | map(.[0:120]) | if length > 0 then " {" + join("; ") + "}" else "" end) end)] | sort | join(" ")' <<<"$apps")
  if [[ "$state" != "${last_state:-}" ]]; then
    echo "[+${elapsed}s] ${ready}/${total} ready: ${state}"
    last_state=$state
  fi
  if [[ "$total" -ge "$EXPECTED" && "$ready" -eq "$total" ]]; then
    echo "platform ready: ${ready}/${total} apps Synced+Healthy after ${elapsed}s"
    exit 0
  fi
  if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
    echo "timeout after ${elapsed}s: ${ready}/${total} apps ready" >&2
    jq -r '.items[] | "\(.metadata.name)\t\(.status.sync.status)\t\(.status.health.status)\t\(.status.conditions // [] | map(.message) | join("; "))"' <<<"$apps" >&2
    exit 1
  fi
  sleep 2
done
