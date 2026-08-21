#!/usr/bin/env bash
# Stops port-forwards and scales the app/engine/rabbitmq workloads to 0.
# Postgres (and its PVC/data) is left running and untouched — this is a
# "pause", not a destroy.
set -euo pipefail

PID_DIR="$(dirname "$0")/.pids"

echo "==> Stopping port-forwards..."
for name in mgmt-flow rabbitmq; do
  pid_file="${PID_DIR}/${name}.pid"
  if [ -f "${pid_file}" ]; then
    pid="$(cat "${pid_file}")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}"
      echo "   stopped ${name} (pid ${pid})"
    fi
    rm -f "${pid_file}"
  fi
done

echo "==> Scaling workloads down to 0 replicas (data is preserved)..."
kubectl scale deployment/mgmt-flow --replicas=0
kubectl scale deployment/mgmt-flow-engine --replicas=0
kubectl scale deployment/rabbitmq --replicas=0

echo ""
echo "Note: postgres was left running so its data stays warm. To also stop"
echo "it: kubectl scale deployment/postgres --replicas=0"
echo ""
echo "To bring everything back: ./scripts/start.sh"
