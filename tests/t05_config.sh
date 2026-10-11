#!/usr/bin/env bash
# t05 -- Configuration: replication parameters, replicator user, pg_hba.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t05 replication configuration"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

for p in "$PRIMARY" "$REPLICA"; do
  check_match "valid wal_level on $p" "^(replica|hot_standby)$" \
    "$(pod_psql_admin "$p" -tAc 'SHOW wal_level' 2>/dev/null)"
  check_eq "hot_standby=on en $p" "on" \
    "$(pod_psql_admin "$p" -tAc 'SHOW hot_standby' 2>/dev/null)"
  MWS="$(pod_psql_admin "$p" -tAc 'SHOW max_wal_senders' 2>/dev/null)"
  check "max_wal_senders >= 1 on $p (=$MWS)" bash -c "[ ${MWS:-0} -ge 1 ]"
done

# Replication user
check_eq "user $REPL_USER exists" "1" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT count(*) FROM pg_roles WHERE rolname='$REPL_USER'")"
check_eq "user $REPL_USER has the REPLICATION privilege" "t" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT rolreplication FROM pg_roles WHERE rolname='$REPL_USER'")"

# pg_hba allows replication from the network
HBA="$(oc -n "$NS" exec "$PRIMARY" -- cat "$PGDATA_PATH/pg_hba.conf" 2>/dev/null)"
check_contains "pg_hba.conf allows replication connections" "host replication all all" "$HBA"

# Application database and user
check_eq "the app database ($APP_DB) exists" "1" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT count(*) FROM pg_database WHERE datname='$APP_DB'")"
check_eq "the app user ($APP_USER) exists" "1" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT count(*) FROM pg_roles WHERE rolname='$APP_USER'")"

# The app user can connect with its password
check_eq "the app user authenticates correctly" "1" \
  "$(pod_psql "$PRIMARY" -tAc 'SELECT 1' 2>/dev/null)"

# The app configuration arrives through the image include
CONF="$(oc -n "$NS" exec "$PRIMARY" -- cat "$PGDATA_PATH/postgresql.conf" 2>/dev/null)"
check_contains "postgresql.conf includes the image config" "openshift-custom-postgresql.conf" "$CONF"

t_summary
