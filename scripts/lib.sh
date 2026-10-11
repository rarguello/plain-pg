#!/usr/bin/env bash
#
# lib.sh -- common helpers. Sourced from the other scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Requires `oc` in the PATH and being logged in to the cluster.
# Variables: NAMESPACE (default postgresql-lab).

NS="${NAMESPACE:-postgresql-lab}"

# Real PGDATA path of the sclorg image (used by the tests).
# shellcheck disable=SC2034
PGDATA_PATH="/var/lib/pgsql/data/userdata"

cm_value()     { oc -n "$NS" get cm postgresql-role -o jsonpath="{.data.$1}"; }
secret_value() { oc -n "$NS" get secret postgresql-credentials -o jsonpath="{.data.$1}" | base64 -d; }

primary_pod()  { cm_value PRIMARY_POD; }

# Prints the pods that are NOT the declared primary (the replicas).
replica_pods() {
  local p; p="$(primary_pod)"
  db_pods | grep -vx "$p" || true
}

# Prints the database pods (primary + replicas), sorted.
db_pods() {
  oc -n "$NS" get pods \
    -l app.kubernetes.io/name=postgresql,app.kubernetes.io/component=database \
    -o name 2>/dev/null | sed 's#pod/##' | sort
}

load_credentials() {
  APP_USER="$(secret_value POSTGRESQL_USER)"
  APP_DB="$(secret_value POSTGRESQL_DATABASE)"
  APP_PASSWORD="$(secret_value POSTGRESQL_PASSWORD)"
  ADMIN_PASSWORD="$(secret_value POSTGRESQL_ADMIN_PASSWORD)"
  # shellcheck disable=SC2034
  REPL_USER="$(secret_value POSTGRESQL_MASTER_USER)"
  # shellcheck disable=SC2034
  REPL_PASSWORD="$(secret_value POSTGRESQL_MASTER_PASSWORD)"
}

# psql as the app user, against 127.0.0.1 inside the pod.
pod_psql() {
  local pod="$1"; shift
  oc -n "$NS" exec "$pod" -- env PGPASSWORD="$APP_PASSWORD" \
    psql -h 127.0.0.1 -U "$APP_USER" -d "$APP_DB" "$@"
}

# psql as superuser (postgres), against 127.0.0.1 inside the pod.
pod_psql_admin() {
  local pod="$1"; shift
  oc -n "$NS" exec "$pod" -- env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h 127.0.0.1 -U postgres -d postgres "$@"
}

# psql as superuser against an arbitrary host (to test Services/DNS).
pod_psql_host() {
  local pod="$1" host="$2"; shift 2
  oc -n "$NS" exec "$pod" -- env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h "$host" -U postgres -d postgres "$@"
}

# Returns 'f' if the pod is primary, 't' if it is standby, empty if it does not respond.
pod_in_recovery() {
  pod_psql_admin "$1" -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null || true
}

# Waits for a Job to finish (Complete or Failed). Prints Complete|Failed|Timeout.
# (`oc wait --for=condition=complete` does not work for a Job that fails: it
#  would keep waiting until the timeout.)
wait_job_done() {
  local job="$1" timeout="${2:-1800}" i=0 cond
  while [ "$i" -lt "$timeout" ]; do
    cond="$(oc -n "$NS" get job "$job" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null || true)"
    case "$cond" in
      *Complete=True*) echo Complete; return 0 ;;
      *Failed=True*)   echo Failed;   return 0 ;;
    esac
    sleep 5; i=$((i + 5))
  done
  echo Timeout
  return 0
}

# Counts the replicas in 'streaming' state according to the primary.
streaming_count() {
  pod_psql_admin "$1" -tAc \
    "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'" 2>/dev/null || echo 0
}

# Waits for the DB pods to be Ready.
# (The StatefulSet uses updateStrategy OnDelete, where `oc rollout status` does
#  not apply: "rollout status is only available for RollingUpdate strategy type".)
# Usage: wait_db_ready [expected_count]
wait_db_ready() {
  local want="${1:-$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}' 2>/dev/null)}"
  want="${want:-2}"
  local i=0 ready
  while [ "$i" -lt 300 ]; do
    ready="$(oc -n "$NS" get pods \
      -l app.kubernetes.io/name=postgresql,app.kubernetes.io/component=database \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
      | grep -c true || true)"
    [ "${ready:-0}" -ge "$want" ] && return 0
    sleep 5; i=$((i + 5))
  done
  return 1
}
