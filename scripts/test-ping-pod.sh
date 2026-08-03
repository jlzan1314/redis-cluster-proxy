#!/usr/bin/env sh
set -eu

POD="${1:?usage: test-ping-pod.sh POD [NAMESPACE] [COUNT]}"
NAMESPACE="${2:-redis}"
COUNT="${3:-100000}"

kubectl exec -i -n "$NAMESPACE" "$POD" -- sh -s -- "$COUNT" <<'SCRIPT'
set -eu

COUNT="$1"
HOST=127.0.0.1
PORT=7777
READY_FILE="/tmp/ping-load-ready.$$"
PIPE_OUTPUT="/tmp/ping-load-output.$$"

cleanup() {
  rm -f "$READY_FILE" "$PIPE_OUTPUT"
}
trap cleanup EXIT

used_memory() {
  redis-cli -h "$HOST" -p "$PORT" --raw PROXY INFO MEMORY \
    | awk -F: '/^used_memory:/{gsub("\r", "", $2); print $2; exit}'
}

echo "single_ping=$(redis-cli -h "$HOST" -p "$PORT" --raw PING)"
echo "message_ping=$(redis-cli -h "$HOST" -p "$PORT" --raw PING health-check)"

before=$(used_memory)
(
  i=0
  while [ "$i" -lt "$COUNT" ]; do
    printf '*1\r\n$4\r\nPING\r\n'
    i=$((i + 1))
  done
  : > "$READY_FILE"
  # Keep the redis-cli connection open while used_memory is sampled. The old
  # implementation retains every locally handled PING request until this
  # connection closes; the fixed implementation releases each one promptly.
  sleep 8
) | nc -w 2 "$HOST" "$PORT" >"$PIPE_OUTPUT" &
pipe_pid=$!

i=0
while [ ! -f "$READY_FILE" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "timed out generating PING load" >&2
    exit 1
  fi
  sleep 0.1
done
sleep 2
after=$(used_memory)
delta=$((after - before))

wait "$pipe_pid"
reply_count=$(wc -l < "$PIPE_OUTPUT" | tr -d ' ')

echo "used_memory_before=$before"
echo "used_memory_during_persistent_ping=$after"
echo "used_memory_delta=$delta"
echo "ping_count=$COUNT"
echo "ping_reply_count=$reply_count"

if [ "$reply_count" -ne "$COUNT" ]; then
  echo "expected $COUNT PING replies, got $reply_count" >&2
  exit 1
fi
SCRIPT
