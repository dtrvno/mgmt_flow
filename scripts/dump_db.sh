#!/usr/bin/env bash
set -euo pipefail

# Snapshots the running Postgres database into the repo so it travels with
# `git clone`/`git pull` — no separate file transfer needed.
#
# Run this on the machine currently running the stack (docker compose up),
# then commit + push:
#   ./scripts/dump_db.sh
#   git add db/backup/mgmtflow_dump.sql.gz
#   git commit -m "Update db snapshot"
#   git push

COMPOSE_PROJECT="${COMPOSE_PROJECT:-mgmt_flow}"
DB_CONTAINER="${DB_CONTAINER:-${COMPOSE_PROJECT}-db-1}"
OUT="db/backup/mgmtflow_dump.sql.gz"

if ! docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container '$DB_CONTAINER' not found. Is the stack running (docker compose up)?" >&2
  echo "Set DB_CONTAINER=<name> or COMPOSE_PROJECT=<project> if your setup uses different names." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

echo "==> Dumping Postgres ($DB_CONTAINER) -> $OUT"
docker exec "$DB_CONTAINER" pg_dump -U mgmtflow --clean --if-exists mgmtflow | gzip > "$OUT"

echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "Now commit and push so the new machine picks it up:"
echo "  git add $OUT"
echo "  git commit -m 'Update db snapshot'"
echo "  git push"
