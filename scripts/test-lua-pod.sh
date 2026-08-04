#!/usr/bin/env sh
set -eu

POD="${1:?usage: test-lua-pod.sh POD [NAMESPACE] [supported|unsupported]}"
NAMESPACE="${2:-redis}"
EXPECTED="${3:-supported}"

kubectl exec -i -n "$NAMESPACE" "$POD" -- sh -s -- "$EXPECTED" <<'SCRIPT'
set -eu

EXPECTED="$1"
HOST=127.0.0.1
PORT=7777
KEY="{lua-pod-check}:$$"
SCRIPT_BODY='return redis.call("SET",KEYS[1],ARGV[1])'
PASSWORD=$(awk '$1 == "auth" { print $2; exit }' /etc/redis/proxy.conf)
if [ -z "$PASSWORD" ]; then
  echo "missing auth password in /etc/redis/proxy.conf" >&2
  exit 1
fi
export REDISCLI_AUTH="$PASSWORD"

eval_reply=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  EVAL "$SCRIPT_BODY" 1 "$KEY" eval-value 2>&1 || true)
script_load_reply=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  SCRIPT LOAD "$SCRIPT_BODY" 2>&1 || true)

echo "eval_with_key=$eval_reply"
echo "script_load=$script_load_reply"

if [ "$EXPECTED" = unsupported ]; then
  case "$eval_reply" in
    ERR*) ;;
    *) echo "expected keyed EVAL to be unsupported" >&2; exit 1 ;;
  esac
  case "$script_load_reply" in
    ERR*) ;;
    *) echo "expected SCRIPT LOAD to be unsupported" >&2; exit 1 ;;
  esac
  exit 0
fi

if [ "$eval_reply" != OK ]; then
  echo "keyed EVAL failed" >&2
  exit 1
fi
eval_value=$(redis-cli -h "$HOST" -p "$PORT" --raw GET "$KEY")
if [ "$eval_value" != eval-value ]; then
  echo "keyed EVAL stored unexpected value: $eval_value" >&2
  exit 1
fi

case "$script_load_reply" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) echo "SCRIPT LOAD returned an invalid SHA" >&2; exit 1 ;;
esac

script_exists=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  SCRIPT EXISTS "$script_load_reply")
evalsha_reply=$(redis-cli -h "$HOST" -p "$PORT" --raw \
  EVALSHA "$script_load_reply" 1 "$KEY" evalsha-value)
evalsha_value=$(redis-cli -h "$HOST" -p "$PORT" --raw GET "$KEY")
redis-cli -h "$HOST" -p "$PORT" DEL "$KEY" >/dev/null

echo "script_exists=$script_exists"
echo "evalsha_with_key=$evalsha_reply"
echo "evalsha_value=$evalsha_value"

[ "$script_exists" = 1 ]
[ "$evalsha_reply" = OK ]
[ "$evalsha_value" = evalsha-value ]
SCRIPT
