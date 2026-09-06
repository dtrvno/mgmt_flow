#!/usr/bin/env bash
set -euo pipefail

# One-time bootstrap for a brand-new machine. Checks prerequisites, builds
# the app/engine images (the "first-time setup" step from RUNBOOK.md), then
# hands off to start.sh, which creates the kind cluster, applies the k8s
# manifests, initializes the database structure (scripts/init_db.sh), and
# starts port-forwards.
#
# Usage:
#   git clone <repo-url>
#   cd mgmt_flow
#   ./scripts/install.sh
#
# Requires Docker, kind, and kubectl installed and on PATH.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "==> Checking prerequisites..."
missing=()
for cmd in docker kind kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required tool(s): ${missing[*]}" >&2
  echo "On macOS with Homebrew:" >&2
  echo "  brew install kind kubectl" >&2
  echo "  brew install --cask docker   # then launch Docker Desktop once" >&2
  exit 1
fi

echo "==> Checking Docker is running..."
if ! docker info > /dev/null 2>&1; then
  echo "ERROR: Docker doesn't seem to be running. Start Docker Desktop, then re-run this script." >&2
  exit 1
fi

echo "==> Building images..."
docker build -t mgmt-flow-static:latest .
docker build -f Dockerfile.engine -t mgmt-flow-engine:latest .

echo "==> Handing off to start.sh (creates kind cluster, applies manifests, initializes db, starts port-forwards)"
exec "$SCRIPT_DIR/start.sh"
