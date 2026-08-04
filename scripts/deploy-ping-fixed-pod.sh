#!/usr/bin/env sh
set -eu

NAMESPACE="${NAMESPACE:-redis}"
POD="${POD:-redis-cluster-proxy-ping-fixed-1-0-0}"
TEST_OLD="${TEST_OLD:-false}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT_DIR/deploy/kubernetes/redis-cluster-proxy-1.0.0-pod.yaml"
SERVICE_MANIFEST="$ROOT_DIR/deploy/kubernetes/redis-cluster-proxy-1.0.0-service.yaml"

# This creates an independent canary Pod. It intentionally does not change or
# delete the existing redis-cluster-proxy Deployment/Pod/Service.
if kubectl get pod -n "$NAMESPACE" "$POD" >/dev/null 2>&1; then
  # Recreate only the canary so imagePullPolicy=Always resolves the current
  # image digest when the explicit version tag is rebuilt.
  kubectl delete pod -n "$NAMESPACE" "$POD" --wait=true
fi
kubectl apply -f "$MANIFEST"
kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$POD" --timeout=180s
kubectl apply -f "$SERVICE_MANIFEST"
kubectl get pod -n "$NAMESPACE" "$POD" -o wide
kubectl get service -n "$NAMESPACE" redis-cluster-proxy-ping-fixed -o wide
kubectl get endpoints -n "$NAMESPACE" redis-cluster-proxy-ping-fixed -o wide

OLD_POD=$(kubectl get pod -n "$NAMESPACE" \
  -l app=redis-cluster-proxy \
  -o jsonpath='{.items[0].metadata.name}')

echo "old pod: $OLD_POD"
if [ "$TEST_OLD" = "true" ]; then
  # The old implementation leaks each persistent PING request. Keep this
  # comparison opt-in so routine canary redeployments do not add avoidable
  # memory pressure to the production Pod.
  "$ROOT_DIR/scripts/test-ping-pod.sh" "$OLD_POD" "$NAMESPACE"
  "$ROOT_DIR/scripts/test-lua-pod.sh" "$OLD_POD" "$NAMESPACE" unsupported
else
  echo "old pod tests skipped (set TEST_OLD=true to compare again)"
fi
echo "new pod: $POD"
"$ROOT_DIR/scripts/test-auth-pod.sh" "$POD" "$NAMESPACE" required
"$ROOT_DIR/scripts/test-ping-pod.sh" "$POD" "$NAMESPACE"
"$ROOT_DIR/scripts/test-lua-pod.sh" "$POD" "$NAMESPACE" supported
NAMESPACE="$NAMESPACE" POD="$POD" "$ROOT_DIR/scripts/test-gozero-pod.sh"
