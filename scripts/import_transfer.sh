#!/usr/bin/env bash
set -euo pipefail

# Brings up mgmt_flow on a new machine from a `git clone`/`git pull`,
# restoring the Postgres snapshot committed at db/backup/mgmtflow_dump.sql.gz
# (produced by scripts/dump_db.sh on the source machine).
#
# Usage:
#   git clone <repo-url>
#   cd mgmt_flow
#   ./scripts/import_transfer.sh
#
# Requires Docker (with `docker compose`) installed and running.

COMPOSE_PROJECT="${COMPOSE_PROJECT:-mgmt_flow}"
DB_CONTAINER="${COMPOSE_PROJECT}-db-1"
DUMP="db/backup/mgmtflow_dump.sql.gz"

[ -f "docker-compose.yml" ] || { echo "ERROR: run this from the repo root (docker-compose.yml not found)." >&2; exit 1; }
[ -f "$DUMP" ] || { echo "ERROR: no snapshot at $DUMP. Run scripts/dump_db.sh on the source machine, commit it, and pull again." >&2; exit 1; }

echo "==> Starting Postgres + RabbitMQ (fresh volumes, so db/init/*.sql runs first)"
docker compose -p "$COMPOSE_PROJECT" up -d db rabbitmq

echo "==> Waiting for Postgres to become healthy"
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null)" = "healthy" ]; do
  sleep 1
done

echo "==> Restoring database snapshot (overwrites the seeded schema/data with the real data)"
gunzip -c "$DUMP" | docker exec -i "$DB_CONTAINER" psql -U mgmtflow -d mgmtflow -v ON_ERROR_STOP=1

echo "==> Building and starting the app + engine"
docker compose -p "$COMPOSE_PROJECT" up -d --build

echo
echo "==> Done."
echo "Dashboard:        http://localhost:3000"
echo "RabbitMQ UI:      http://localhost:15672  (guest/guest)"
echo "Engine /health:   http://localhost:5001/health"
