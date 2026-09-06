#!/usr/bin/env bash
# Runs through the checks in HEALTHCHECK.md automatically and prints a
# pass/fail summary. Exits non-zero if anything fails, so it's safe to use
# in other scripts (e.g. before running a smoke test).
set -uo pipefail

PASS="✅"
FAIL="❌"
WARN="⚠️ "
overall_ok=true

section() { echo ""; echo "== $1 =="; }

# --- 1. Cluster reachable ------------------------------------------------
section "1. Kind cluster"
if kubectl cluster-info --context kind-kind > /dev/null 2>&1; then
  echo "${PASS} cluster is reachable"
else
  echo "${FAIL} cluster is NOT reachable (is Docker Desktop running?)"
  overall_ok=false
  echo ""
  echo "Stopping here — nothing else can be checked without the cluster."
  exit 1
fi

# --- 2. Pods running ------------------------------------------------------
section "2. Pods"
pod_line() {
  local label="$1"
  local line
  line="$(kubectl get pods -l "${label}" --no-headers 2>/dev/null)"
  if [ -z "${line}" ]; then
    echo "${FAIL} no pods found for ${label}"
    overall_ok=false
    return
  fi
  while IFS= read -r row; do
    name="$(echo "$row" | awk '{print $1}')"
    ready="$(echo "$row" | awk '{print $2}')"
    status="$(echo "$row" | awk '{print $3}')"
    restarts="$(echo "$row" | awk '{print $4}')"
    ready_num="${ready%%/*}"
    ready_denom="${ready##*/}"
    if [ "${status}" = "Running" ] && [ -n "${ready_num}" ] && [ "${ready_num}" = "${ready_denom}" ] && [ "${ready_num}" -gt 0 ] 2>/dev/null; then
      echo "${PASS} ${name}  ready=${ready}  status=${status}  restarts=${restarts}"
    else
      echo "${FAIL} ${name}  ready=${ready}  status=${status}  restarts=${restarts}"
      overall_ok=false
    fi
  done <<< "${line}"
}
pod_line "app=mgmt-flow"
pod_line "app=mgmt-flow-engine"
pod_line "app=postgres"
pod_line "app=rabbitmq"

# --- 3. Engine actually connected ----------------------------------------
section "3. Engine connected to RabbitMQ"
if kubectl logs -l app=mgmt-flow-engine --tail=200 2>/dev/null | grep -q "waiting for tasks on"; then
  echo "${PASS} engine has logged its 'waiting for tasks' startup line"
else
  echo "${WARN} startup line not seen in last 200 log lines (may have scrolled past, or engine isn't consuming yet)"
fi

# --- 4. Dashboard reachable -----------------------------------------------
section "4. Dashboard (http://localhost:8080)"
if curl -sf -o /dev/null --max-time 3 http://localhost:8080; then
  echo "${PASS} dashboard reachable"
else
  echo "${FAIL} dashboard NOT reachable (port-forward running? try: kubectl port-forward svc/mgmt-flow 8080:3000)"
  overall_ok=false
fi

# --- 5. Database schema present -------------------------------------------
section "5. Database schema"
PG_POD="$(kubectl get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "${PG_POD}" ]; then
  TABLES="$(kubectl exec "${PG_POD}" -- psql -U mgmtflow -d mgmtflow -tAc \
    "SELECT string_agg(tablename, ',') FROM pg_tables WHERE schemaname='public';" 2>/dev/null)"
  for t in workflows jobs flow_definitions flow_tasks; do
    if echo "${TABLES}" | grep -qw "${t}"; then
      echo "${PASS} table '${t}' exists"
    else
      echo "${FAIL} table '${t}' missing — schema not loaded (see RUNBOOK.md)"
      overall_ok=false
    fi
  done
else
  echo "${FAIL} could not find a postgres pod"
  overall_ok=false
fi

# --- Summary ---------------------------------------------------------------
section "Summary"
if [ "${overall_ok}" = true ]; then
  echo "${PASS} All checks passed. For a full end-to-end confirmation, start a"
  echo "   flow run from the dashboard and watch: kubectl get jobs -w"
  exit 0
else
  echo "${FAIL} One or more checks failed — see above, and RUNBOOK.md for fixes."
  exit 1
fi
