#!/usr/bin/env bash
# t05 -- Configuracion: parametros de replicacion, usuario replicador, pg_hba.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t05 configuracion de replicacion"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

for p in "$PRIMARY" "$REPLICA"; do
  check_match "wal_level valido en $p" "^(replica|hot_standby)$" \
    "$(pod_psql_admin "$p" -tAc 'SHOW wal_level' 2>/dev/null)"
  check_eq "hot_standby=on en $p" "on" \
    "$(pod_psql_admin "$p" -tAc 'SHOW hot_standby' 2>/dev/null)"
  MWS="$(pod_psql_admin "$p" -tAc 'SHOW max_wal_senders' 2>/dev/null)"
  check "max_wal_senders >= 1 en $p (=$MWS)" bash -c "[ ${MWS:-0} -ge 1 ]"
done

# Usuario de replicacion
check_eq "el usuario $REPL_USER existe" "1" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT count(*) FROM pg_roles WHERE rolname='$REPL_USER'")"
check_eq "el usuario $REPL_USER tiene privilegio REPLICATION" "t" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT rolreplication FROM pg_roles WHERE rolname='$REPL_USER'")"

# pg_hba permite replication desde la red
HBA="$(oc -n "$NS" exec "$PRIMARY" -- cat "$PGDATA_PATH/pg_hba.conf" 2>/dev/null)"
check_contains "pg_hba.conf permite conexiones de replication" "host replication all all" "$HBA"

# Base y usuario de la aplicacion
check_eq "existe la base de la app ($APP_DB)" "1" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT count(*) FROM pg_database WHERE datname='$APP_DB'")"
check_eq "existe el usuario de la app ($APP_USER)" "1" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT count(*) FROM pg_roles WHERE rolname='$APP_USER'")"

# El usuario de la app puede conectarse con su password
check_eq "el usuario de la app autentica correctamente" "1" \
  "$(pod_psql "$PRIMARY" -tAc 'SELECT 1' 2>/dev/null)"

# La configuracion de la app llega por el include de la imagen
CONF="$(oc -n "$NS" exec "$PRIMARY" -- cat "$PGDATA_PATH/postgresql.conf" 2>/dev/null)"
check_contains "postgresql.conf incluye la config de la imagen" "openshift-custom-postgresql.conf" "$CONF"

t_summary
