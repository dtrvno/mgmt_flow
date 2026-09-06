#!/usr/bin/env bash
set -euo pipefail

# Creates/updates the database structure (schema + seed flows) on the
# `postgres` Deployment running in the kind cluster.
#
# Unlike docker-compose's official postgres image, the k8s postgres.yaml
# Deployment has no docker-entrypoint-initdb.d equivalent — nothing applies
# db/init/*.sql automatically on a fresh PVC. This script does that job, and
# is safe to re-run any time (every db/init/*.sql script is idempotent).

NAMESPACE="${NAMESPACE:-default}"
DB_USER="${DB_USER:-mgmtflow}"
DB_NAME="${DB_NAME:-mgmtflow}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Waiting for postgres Deployment to be ready..."
kubectl rollout status deployment/postgres -n "$NAMESPACE" --timeout=300s

POD="$(kubectl get pod -l app=postgres -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')"

for f in "$REPO_ROOT"/db/init/*.sql; do
  echo "==> Applying $(basename "$f")"
  kubectl exec -i -n "$NAMESPACE" "$POD" -- psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$f"
done

echo "==> Database structure ready."
