#!/usr/bin/env bash
#
# lib.sh -- helpers comunes. Se sourcea desde los otros scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Requiere `oc` en el PATH y estar logueado en el cluster.
# Variables: NAMESPACE (default pg-ha-lab).

NS="${NAMESPACE:-pg-ha-lab}"

# Ruta PGDATA real de la imagen sclorg (la usan los tests).
# shellcheck disable=SC2034
PGDATA_PATH="/var/lib/pgsql/data/userdata"

cm_value()     { oc -n "$NS" get cm postgres-role -o jsonpath="{.data.$1}"; }
secret_value() { oc -n "$NS" get secret postgres-credentials -o jsonpath="{.data.$1}" | base64 -d; }

primary_pod()  { cm_value PRIMARY_POD; }

# Imprime los pods que NO son el primary declarado (las replicas).
replica_pods() {
  local p; p="$(primary_pod)"
  db_pods | grep -vx "$p" || true
}

# Imprime los pods de la base de datos (primary + replicas), ordenados.
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

# psql como usuario de la app, contra 127.0.0.1 dentro del pod.
pod_psql() {
  local pod="$1"; shift
  oc -n "$NS" exec "$pod" -- env PGPASSWORD="$APP_PASSWORD" \
    psql -h 127.0.0.1 -U "$APP_USER" -d "$APP_DB" "$@"
}

# psql como superusuario (postgres), contra 127.0.0.1 dentro del pod.
pod_psql_admin() {
  local pod="$1"; shift
  oc -n "$NS" exec "$pod" -- env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h 127.0.0.1 -U postgres -d postgres "$@"
}

# psql como superusuario contra un host arbitrario (para probar Services/DNS).
pod_psql_host() {
  local pod="$1" host="$2"; shift 2
  oc -n "$NS" exec "$pod" -- env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h "$host" -U postgres -d postgres "$@"
}

# Devuelve 'f' si el pod es primary, 't' si es standby, vacio si no responde.
pod_in_recovery() {
  pod_psql_admin "$1" -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null || true
}

# Cuenta las replicas en estado 'streaming' segun el primary.
streaming_count() {
  pod_psql_admin "$1" -tAc \
    "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'" 2>/dev/null || echo 0
}

# Espera a que los pods de la BD esten Ready.
# (El StatefulSet usa updateStrategy OnDelete, donde `oc rollout status` no
#  aplica: "rollout status is only available for RollingUpdate strategy type".)
# Uso: wait_db_ready [cantidad_esperada]
wait_db_ready() {
  local want="${1:-$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.replicas}' 2>/dev/null)}"
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
