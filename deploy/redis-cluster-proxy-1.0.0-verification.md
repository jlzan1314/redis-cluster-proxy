# redis-cluster-proxy 1.0.0 deployment verification

Date: 2026-08-03 (Asia/Shanghai)

## Image

- Tag: `gamesirnanjing.asuscomm.com:5000/gamehub/redis-cluster-proxy:1.0.0`
- Digest: `sha256:1846e715307371731177a7de17bc861c5413b142c40c17b9c71f3cf62217ab1a`
- Source branch: `fix/ping-request-leak`
- Image source revision: `addeab980ebb90af8cc8654d5325cbc581024019`

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
used_memory_before=78019209
used_memory_during_persistent_ping=122421614
used_memory_delta=44402405
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

## Replay

```sh
./scripts/build-push-image.sh
./scripts/deploy-ping-fixed-pod.sh
```

`deploy-ping-fixed-pod.sh` intentionally does not update or delete the old
Deployment, Pod, or Service.
