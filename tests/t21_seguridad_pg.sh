#!/usr/bin/env bash
# t21 -- Seguridad a nivel PostgreSQL: privilegios minimos y pg_hba.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t21 seguridad PostgreSQL"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

# El usuario de la app no debe ser superusuario ni poder crear roles/bases
check_eq "el usuario de la app NO es superusuario" "f" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='$APP_USER'")"
check_eq "el usuario de la app NO puede crear roles" "f" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT rolcreaterole FROM pg_roles WHERE rolname='$APP_USER'")"
check_eq "el usuario de la app NO puede crear bases" "f" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT rolcreatedb FROM pg_roles WHERE rolname='$APP_USER'")"

# La replica rechaza DDL (no solo DML)
ddl_fails() { ! pod_psql "$1" -q -c "CREATE TABLE t_should_fail(x int)" >/dev/null 2>&1; }
check "la replica rechaza DDL (CREATE TABLE)" ddl_fails "$REPLICA"

# pg_hba no debe permitir 'trust' para conexiones de red
HBA="$(oc -n "$NS" exec "$PRIMARY" -- cat "$PGDATA_PATH/pg_hba.conf" 2>/dev/null)"
check "pg_hba no permite 'trust' en conexiones host" \
  bash -c "! printf '%s' \"\$HBA\" | grep -E '^host' | grep -qw trust"

# El superusuario por TCP exige password
check "el superusuario no entra por TCP sin password" \
  bash -c "! oc -n $NS exec $PRIMARY -- env PGPASSWORD=wrong psql -h 127.0.0.1 -U postgres -tAc 'SELECT 1' >/dev/null 2>&1"

# El usuario de replicacion no debe poder escribir en la base de la app
check "el usuario de replicacion no es dueño de la base de la app" \
  bash -c "[ \"\$(oc -n $NS exec $PRIMARY -- env PGPASSWORD=$ADMIN_PASSWORD psql -h 127.0.0.1 -U postgres -tAc \"SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$APP_DB'\")\" != '$REPL_USER' ]"

t_summary
