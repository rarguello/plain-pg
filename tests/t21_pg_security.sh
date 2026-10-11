#!/usr/bin/env bash
# t21 -- PostgreSQL-level security: minimal privileges and pg_hba.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t21 PostgreSQL security"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

# The app user must not be superuser or be able to create roles/databases
check_eq "the app user is NOT superuser" "f" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='$APP_USER'")"
check_eq "the app user can NOT create roles" "f" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT rolcreaterole FROM pg_roles WHERE rolname='$APP_USER'")"
check_eq "the app user can NOT create databases" "f" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT rolcreatedb FROM pg_roles WHERE rolname='$APP_USER'")"

# The replica rejects DDL (not only DML)
ddl_fails() { ! pod_psql "$1" -q -c "CREATE TABLE t_should_fail(x int)" >/dev/null 2>&1; }
check "the replica rejects DDL (CREATE TABLE)" ddl_fails "$REPLICA"

# pg_hba: REMOTE connections (from another pod) must ask for a password.
# Local ones (127.0.0.1) stay at 'trust' by initdb default: it is equivalent to
# having a shell in the container (see docs/technical-notes.md).
HBA="$(oc -n "$NS" exec "$PRIMARY" -- cat "$PGDATA_PATH/pg_hba.conf" 2>/dev/null)"
hba_remote_without_trust() {
  ! printf '%s\n' "$HBA" | grep -E '^host' | grep -vE '127\.0\.0\.1|::1' | grep -qw trust
}
check "pg_hba does not allow 'trust' on remote connections" hba_remote_without_trust

# The superuser must not get in FROM ANOTHER POD without the correct password.
remote_wrong_password_fails() {
  ! oc -n "$NS" exec "$REPLICA" -- env PGPASSWORD=incorrecta psql \
      -h "${PRIMARY}.postgresql-hl.${NS}.svc.cluster.local" -U postgres \
      -d postgres -tAc 'SELECT 1' >/dev/null 2>&1
}
check "the superuser does not get in from another pod with a wrong password" remote_wrong_password_fails

# The replication user must not be able to write to the app database
check "the replication user is not the owner of the app database" \
  bash -c "[ \"\$(oc -n $NS exec $PRIMARY -- env PGPASSWORD=$ADMIN_PASSWORD psql -h 127.0.0.1 -U postgres -tAc \"SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$APP_DB'\")\" != '$REPL_USER' ]"

t_summary
