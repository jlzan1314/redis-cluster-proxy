#!/usr/bin/env sh
set -eu

IMAGE="${IMAGE:-gamesirnanjing.asuscomm.com:5000/gamehub/redis-cluster-proxy:1.0.0}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REVISION=$(git -C "$ROOT_DIR" rev-parse HEAD)

docker build --pull \
  --label "org.opencontainers.image.revision=$REVISION" \
  -t "$IMAGE" "$ROOT_DIR"
docker push "$IMAGE"
docker image inspect "$IMAGE" --format 'image={{index .RepoDigests 0}} id={{.Id}}'
