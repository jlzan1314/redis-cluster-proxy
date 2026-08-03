# redis-cluster-proxy 1.0.0 deployment verification

Date: 2026-08-03 (Asia/Shanghai)

## Image

- Tag: `gamesirnanjing.asuscomm.com:5000/gamehub/redis-cluster-proxy:1.0.0`
- Digest: `sha256:9dac1d15e8e572c06095e4d29402d976243047649129c2d9a9f887ba75ef5c7c`
- Source branch: `fix/ping-request-leak`
- Image source revision: `cb9c24bd970a58c019e1dbbe1866a94ae85e5d75`

## Pods

- Existing Pod retained: `redis/redis-cluster-proxy-5787cc497d-ch692`
- Independent fixed Pod created: `redis/redis-cluster-proxy-ping-fixed-1-0-0`
- The existing Service still has only the old Pod endpoint. The fixed Pod is a
  canary and does not receive production Service traffic.

## PING verification

Command:

```sh
./scripts/test-ping-pod.sh POD redis 100000
```

Old Pod:

```text
single_ping=PONG
message_ping=PONG
used_memory_before=32417552
used_memory_during_persistent_ping=80748221
used_memory_delta=48330669
ping_count=100000
ping_reply_count=100000
```

Fixed Pod:

```text
single_ping=PONG
message_ping=health-check
used_memory_before=18238741
used_memory_during_persistent_ping=18253578
used_memory_delta=14837
ping_count=100000
ping_reply_count=100000
```

Both Pods respond to `PING`. The old implementation retains locally handled
PING requests on a persistent connection, while the fixed implementation
releases them immediately. The old Pod has previously restarted 110 times and
its last terminated state is `OOMKilled`, matching this leak.

## Lua verification

Command:

```sh
./scripts/test-lua-pod.sh POD redis supported
```

Old Pod:

```text
eval_with_key=ERR Cross-slot queries are not supported for this command
script_load=ERR unsupported command `script`
```

Fixed Pod:

```text
eval_with_key=OK
script_load=9f2518cfb250161b7ed902a374cc2dc096a09e8b
script_exists=1
evalsha_with_key=OK
evalsha_value=evalsha-value
```

The fixed implementation corrects the EVAL/EVALSHA `numkeys` range and sends
SCRIPT LOAD/EXISTS/FLUSH to every master. A Go program using
`github.com/redis/go-redis/v9` also passed `redis.NewScript().Run`,
`ScriptLoad`, and `ScriptExists` through the fixed Pod.

## Replay

```sh
./scripts/build-push-image.sh
./scripts/deploy-ping-fixed-pod.sh
```

`deploy-ping-fixed-pod.sh` intentionally does not update or delete the old
Deployment, Pod, or Service.
