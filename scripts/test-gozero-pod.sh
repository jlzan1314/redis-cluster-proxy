#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-redis}
POD=${POD:-redis-cluster-proxy-ping-fixed-1-0-0}
LOCAL_PORT=${LOCAL_PORT:-17779}
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LOG_FILE=$(mktemp)

cleanup() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

kubectl port-forward -n "$NAMESPACE" "pod/$POD" \
  "$LOCAL_PORT:7777" >"$LOG_FILE" 2>&1 &
PORT_FORWARD_PID=$!

for _ in $(seq 1 50); do
  if grep -q 'Forwarding from' "$LOG_FILE"; then
    break
  fi
  if ! kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
    cat "$LOG_FILE" >&2
    exit 1
  fi
  sleep 0.1
done

grep -q 'Forwarding from' "$LOG_FILE" || {
  cat "$LOG_FILE" >&2
  echo "port-forward did not become ready" >&2
  exit 1
}

(
  cd "$ROOT_DIR/test/gozero"
  go run . "127.0.0.1:$LOCAL_PORT"
)
