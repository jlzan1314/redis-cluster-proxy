#!/usr/bin/env sh
set -eu

NAMESPACE="${NAMESPACE:-redis}"
POD="${POD:-redis-cluster-proxy-ping-fixed-1-0-0}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT_DIR/deploy/kubernetes/redis-cluster-proxy-1.0.0-pod.yaml"

# This creates an independent canary Pod. It intentionally does not change or
# delete the existing redis-cluster-proxy Deployment/Pod/Service.
kubectl apply -f "$MANIFEST"
kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$POD" --timeout=180s
kubectl get pod -n "$NAMESPACE" "$POD" -o wide

OLD_POD=$(kubectl get pod -n "$NAMESPACE" \
  -l app=redis-cluster-proxy \
  -o jsonpath='{.items[0].metadata.name}')

echo "old pod: $OLD_POD"
"$ROOT_DIR/scripts/test-ping-pod.sh" "$OLD_POD" "$NAMESPACE"
echo "new pod: $POD"
"$ROOT_DIR/scripts/test-ping-pod.sh" "$POD" "$NAMESPACE"
