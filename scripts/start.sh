#!/usr/bin/env bash
# Starts the full mgmt_flow stack on the local kind cluster and opens
# port-forwards in the background. Safe to re-run — every step is idempotent.
set -euo pipefail

CLUSTER_NAME="kind"
NAMESPACE="default"
PID_DIR="$(dirname "$0")/.pids"
mkdir -p "$PID_DIR"

echo "==> Checking Docker is running..."
if ! docker info > /dev/null 2>&1; then
  echo "Docker doesn't seem to be running. Start Docker Desktop, then re-run this script."
  exit 1
fi

echo "==> Checking kind cluster '${CLUSTER_NAME}'..."
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "No kind cluster named '${CLUSTER_NAME}' found. Creating one..."
  kind create cluster --name "${CLUSTER_NAME}"
else
  if ! kubectl cluster-info --context "kind-${CLUSTER_NAME}" > /dev/null 2>&1; then
    echo "Cluster container appears stopped. Starting it..."
    docker start "${CLUSTER_NAME}-control-plane" > /dev/null
    echo "Waiting for the API server to come up..."
    for i in $(seq 1 30); do
      if kubectl cluster-info --context "kind-${CLUSTER_NAME}" > /dev/null 2>&1; then
        break
      fi
      sleep 2
    done
  fi
fi

kubectl config use-context "kind-${CLUSTER_NAME}" > /dev/null

echo "==> Ensuring images are loaded into the cluster..."
for img in mgmt-flow-static:latest mgmt-flow-engine:latest; do
  if docker image inspect "${img}" > /dev/null 2>&1; then
    kind load docker-image "${img}" --name "${CLUSTER_NAME}" > /dev/null
  else
    echo "warning: image ${img} not found locally — build it first if this is a fresh checkout:"
    echo "  docker build -t mgmt-flow-static:latest ."
    echo "  docker build -f Dockerfile.engine -t mgmt-flow-engine:latest ."
  fi
done

echo "==> Applying Kubernetes manifests..."
kubectl apply -k k8s/

echo "==> Waiting for workloads to become ready..."
kubectl rollout status deployment/postgres --timeout=120s
kubectl rollout status deployment/rabbitmq --timeout=120s
kubectl rollout status deployment/mgmt-flow --timeout=120s
kubectl rollout status deployment/mgmt-flow-engine --timeout=120s

echo "==> Starting port-forwards in the background..."
nohup kubectl port-forward svc/mgmt-flow 8080:3000 -n "${NAMESPACE}" \
  > "${PID_DIR}/mgmt-flow.log" 2>&1 &
echo $! > "${PID_DIR}/mgmt-flow.pid"

nohup kubectl port-forward svc/rabbitmq 15672:15672 -n "${NAMESPACE}" \
  > "${PID_DIR}/rabbitmq.log" 2>&1 &
echo $! > "${PID_DIR}/rabbitmq.pid"

sleep 2
echo ""
echo "==> mgmt_flow is up:"
echo "    Dashboard:        http://localhost:8080"
echo "    RabbitMQ mgmt UI: http://localhost:15672  (guest/guest)"
echo ""
echo "Run ./scripts/stop.sh to stop port-forwards and scale workloads down."
