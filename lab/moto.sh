#!/usr/bin/env bash
# Local AWS API emulator (moto) used by the local end-to-end runs.
# State is in memory: `reset` wipes every emulated resource.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
NAME=egp-moto
PORT="${MOTO_PORT:-15566}"
IMAGE=motoserver/moto:5.2.5

case "${1:-up}" in
  up)
    if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      docker rm -f "$NAME" >/dev/null 2>&1 || true
      docker run -d --name "$NAME" --restart unless-stopped \
        -e MOTO_IAM_LOAD_MANAGED_POLICIES=true \
        -p "127.0.0.1:${PORT}:5000" "$IMAGE" -p 5000 -s >/dev/null
    fi
    for _ in $(seq 1 30); do
      curl -ksf -o /dev/null "https://127.0.0.1:${PORT}/moto-api/" && { echo "moto up on :${PORT}"; exit 0; }
      sleep 1
    done
    echo "moto did not come up" >&2; exit 1 ;;
  reset)
    curl -ksf -X POST "https://127.0.0.1:${PORT}/moto-api/reset" && echo "moto state reset" ;;
  down)
    docker rm -f "$NAME" >/dev/null 2>&1 || true; echo "moto removed" ;;
  *) echo "usage: $0 up|reset|down" >&2; exit 2 ;;
esac
