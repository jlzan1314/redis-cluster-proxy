#!/usr/bin/env sh
set -eu

POD="${1:?usage: test-auth-pod.sh POD [NAMESPACE] [required|open]}"
NAMESPACE="${2:-redis}"
EXPECTED="${3:-required}"

kubectl exec -i -n "$NAMESPACE" "$POD" -- sh -s -- "$EXPECTED" <<'SCRIPT'
set -eu

EXPECTED="$1"
HOST=127.0.0.1
PORT=7777
PASSWORD=$(awk '$1 == "auth" { print $2; exit }' /etc/redis/proxy.conf)
if [ -z "$PASSWORD" ]; then
  echo "missing auth password in /etc/redis/proxy.conf" >&2
  exit 1
fi

noauth_ping=$(redis-cli -h "$HOST" -p "$PORT" --raw PING 2>&1 || true)
noauth_get=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  GET __redis_cluster_proxy_auth_probe_missing__ 2>&1 || true)
wrong_auth=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  AUTH default definitely-wrong-password 2>&1 || true)

echo "noauth_ping=$noauth_ping"
echo "noauth_get=$noauth_get"
echo "wrong_auth=$wrong_auth"

if [ "$EXPECTED" = open ]; then
  [ "$noauth_ping" = PONG ]
  case "$noauth_get" in
    NOAUTH*) echo "expected unauthenticated GET to be open" >&2; exit 1 ;;
  esac
  exit 0
fi

case "$noauth_ping" in
  NOAUTH*) ;;
  *) echo "expected unauthenticated PING to return NOAUTH" >&2; exit 1 ;;
esac
case "$noauth_get" in
  NOAUTH*) ;;
  *) echo "expected unauthenticated GET to return NOAUTH" >&2; exit 1 ;;
esac
case "$wrong_auth" in
  WRONGPASS*) ;;
  *) echo "expected invalid AUTH to return WRONGPASS" >&2; exit 1 ;;
esac

correct_auth=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  AUTH default "$PASSWORD")
authed_ping=$(REDISCLI_AUTH="$PASSWORD" \
  redis-cli -h "$HOST" -p "$PORT" --raw PING)
authed_get=$(REDISCLI_AUTH="$PASSWORD" \
  redis-cli -h "$HOST" -p "$PORT" --raw \
    GET __redis_cluster_proxy_auth_probe_missing__)
hello_auth=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  HELLO 2 AUTH default "$PASSWORD")
wrong_hello=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  HELLO 2 AUTH default definitely-wrong-password 2>&1 || true)

echo "correct_auth=$correct_auth"
echo "authed_ping=$authed_ping"
echo "authed_get=$authed_get"
echo "hello_auth_server=$(printf '%s\n' "$hello_auth" | \
  awk '/redis-cluster-proxy/ { print; exit }')"
echo "wrong_hello=$wrong_hello"

[ "$correct_auth" = OK ]
[ "$authed_ping" = PONG ]
printf '%s\n' "$hello_auth" | grep -q redis-cluster-proxy
case "$wrong_hello" in
  WRONGPASS*) ;;
  *) echo "expected invalid HELLO AUTH to return WRONGPASS" >&2; exit 1 ;;
esac
SCRIPT
