# redis-cluster-proxy 1.0.0 deployment verification

Date: 2026-08-04 (Asia/Shanghai)

## Image

- Scope: canary Pod only; the original production Deployment is unchanged.
- Tag: `gamesirnanjing.asuscomm.com:5000/gamehub/redis-cluster-proxy:1.0.0`
- Digest: `sha256:0ea244111fd5a680f28ea17e258e313f3bb04ed96fe7c00aa33163a75776534a`
- Source branch: `fix/ping-request-leak`
- Source base revision: `06e92e9fa207ebb8167ca26b6e97b7db3c4de098`
- The downstream authentication changes are in the current working tree; the
  image digest above is the authoritative deployed artifact identity.

## Initial canary Pods (2026-08-03)

- Existing Pod retained: `redis/redis-cluster-proxy-5787cc497d-ch692`
- Independent fixed Pod created: `redis/redis-cluster-proxy-ping-fixed-1-0-0`
- Independent fixed Service created: `redis/redis-cluster-proxy-ping-fixed`
- The existing Service still has only the old Pod endpoint. The fixed Pod is a
  canary and does not receive traffic from the existing production Service.
  The new Service selects only the fixed canary Pod and is available inside
  the cluster at
  `redis-cluster-proxy-ping-fixed.redis.svc.cluster.local:7777`.

Initial Service verification:

```text
service=redis-cluster-proxy-ping-fixed
cluster_ip=172.16.25.50
endpoint=10.16.0.67:7777
pod_ip=10.16.0.67
service_ping=PONG
service_eval=service-ok
service_evalsha=OK
```

The `redis-cluster-proxy` production Service and Deployment remain on the
original image. Only the independent canary Pod and Service use the fixed
image.

## Downstream authentication canary

The ConfigMap already contained `auth-user default` and `auth <password>`, but
the original proxy treated those values only as credentials for its upstream
Redis Cluster connections. It automatically authenticated shared connections,
so a new downstream client could issue `PING`, `GET`, and other commands
without first sending `AUTH`.

The fixed proxy tracks authentication state per downstream client. When
`auth` is configured, only `AUTH` and `HELLO ... AUTH` are accepted until the
client proves the configured credentials. Other commands return
`NOAUTH Authentication required.` and invalid credentials return `WRONGPASS`.
The credentials are still used separately for the proxy's upstream cluster
connections.

Baseline command, run before the fix against both Pods:

```sh
./scripts/test-auth-pod.sh POD redis open
```

Baseline result from both the old production Pod and old canary image:

```text
noauth_ping=PONG
noauth_get=
wrong_auth=WRONGPASS invalid username-password pair or user is disabled.
```

Final command, run against the current canary Pod:

```sh
./scripts/test-auth-pod.sh POD redis required
```

Final result:

```text
noauth_ping=NOAUTH Authentication required.
noauth_get=NOAUTH Authentication required.
wrong_auth=WRONGPASS invalid username-password pair or user is disabled.
correct_auth=OK
authed_ping=PONG
hello_auth_server=redis-cluster-proxy
wrong_hello=WRONGPASS invalid username-password pair or user is disabled.
```

Current production and canary state after restoring the original production
Deployment:

```text
production_pod=redis-cluster-proxy-5787cc497d-4xd8s
production_image=acs-reg.alipay.com/kornrunner/redis-cluster-proxy:latest
production_image_digest=sha256:d81a8e018808493923dee1484c7aba1f74fea31399852c1a2ed88ff254cf8145
production_endpoint=10.16.0.104:7777
production_noauth=PONG
canary_pod=redis-cluster-proxy-ping-fixed-1-0-0
canary_endpoint=10.16.0.98:7777
canary_image_digest=sha256:0ea244111fd5a680f28ea17e258e313f3bb04ed96fe7c00aa33163a75776534a
canary_noauth=NOAUTH Authentication required.
canary_auth=PONG
```

The fixed image is not selected by the production Service. Production remains
open exactly as before; only the canary listener enforces downstream AUTH.

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
all Redis 6 SCRIPT subcommands to every master. A Go program using
`github.com/redis/go-redis/v9` also passed `redis.NewScript().Run`,
`ScriptLoad`, and `ScriptExists` through the fixed Pod.

Additional Redis 6 Lua command verification on the current image:

```text
script_help_has_debug=yes
script_debug_no=OK
script_kill_idle=NOTBUSY No scripts in execution right now.
script_exists_loaded_missing=1,0
eval_two_same_slot=2
script_flush=OK
script_exists_after_flush=0
```

## go-zero breaker verification

Run the go-zero v1.9.0 compatibility and load test against the canary Pod:

```sh
./scripts/test-gozero-pod.sh
```

The test reads the configured password from the mounted proxy configuration
without printing it, passes it through `RedisConf.Pass`, and uses the proxy as
a single Redis endpoint (`Type: node`). It covers
PING, SET/GET/EXISTS/EXPIRE/TTL/INCR, the community hot-score
EXISTS/HMGET/pipeline flow, EVAL/EVALSHA, SCRIPT LOAD, and go-zero
`ScriptRun`. It also creates concurrent connections so the go-redis v9 HELLO
and CLIENT SETINFO handshake is exercised and verifies that the go-zero
breaker stays closed.

Remote services that connect directly to the Redis Cluster continue to use
`Type: cluster`; `Type: node` applies only when the address is this proxy.

Current canary result:

```text
LOAD total=60000 ping=20000 exists=20000 hmget=20000 elapsed=28.869s command_errors=0 ping_false=0 breaker_open=0
PASS go-zero breaker stayed closed
RESULT PASS
```

The first high-concurrency run against the previous canary image exposed
`ERR unsupported command hello`: go-redis v9 sends HELLO when it creates each
connection, and go-zero counted those handshake errors as breaker failures.
The current image handles HELLO and CLIENT SETINFO locally, so the same test
finishes with zero command errors and zero open-breaker responses.

## Direct Redis Cluster verification

The `gamehub-pre` community service currently uses
`redis-cluster.redis-pre.svc.cluster.local:6379` with `Type: cluster`; it does
not traverse redis-cluster-proxy. From the running community Pod, go-zero
v1.9.0 passed the same hot-score EXISTS/HMGET/pipeline flow, PING, and
`ScriptRun` directly against that cluster:

```text
PASS NewRedis type=cluster host=redis-cluster.redis-pre.svc.cluster.local:6379
PASS PING
PASS PIPELINE/HMGET community_hot_score flow
PASS go-zero ScriptRun
LOAD total=15000 elapsed=819ms errors=0 ping_false=0 breaker_open=0
RESULT PASS
```

Therefore the historical community log at `2026-08-03T19:28:05+08:00` was
not produced through this proxy. `circuit breaker is open` is the secondary
go-zero breaker result; the preceding Redis command/network error from that
old community Pod is required to determine its original trigger. The current
community Pod has no matching breaker errors in its available logs.

## Replay

```sh
./scripts/build-push-image.sh
./scripts/deploy-ping-fixed-pod.sh
```

`deploy-ping-fixed-pod.sh` intentionally does not update or delete the old
Deployment, Pod, or Service. Re-testing an old Pod is opt-in with
`TEST_OLD=true` because its persistent PING leak has already been reproduced.
