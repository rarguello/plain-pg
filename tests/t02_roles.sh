#!/usr/bin/env bash
# t02 -- Roles: who is primary and who is replica, and their on-disk consistency.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t02 pod roles"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

check_eq "the ConfigMap declares postgresql-0 as primary" "postgresql-0" "$PRIMARY"
check_eq "the primary is not in recovery" "f" "$(pod_in_recovery "$PRIMARY")"
check_eq "the replica is in recovery" "t" "$(pod_in_recovery "$REPLICA")"

check "the primary does NOT have standby.signal" \
  bash -c "oc -n $NS exec $PRIMARY -- test ! -e $PGDATA_PATH/standby.signal"
check "the primary does NOT have recovery.signal" \
  bash -c "oc -n $NS exec $PRIMARY -- test ! -e $PGDATA_PATH/recovery.signal"
check "the replica DOES have standby.signal" \
  bash -c "oc -n $NS exec $REPLICA -- test -e $PGDATA_PATH/standby.signal"
check "the replica does NOT have recovery.signal" \
  bash -c "oc -n $NS exec $REPLICA -- test ! -e $PGDATA_PATH/recovery.signal"

# the replica's primary_conninfo points at the declared primary
CONNINFO="$(oc -n "$NS" exec "$REPLICA" -- cat /var/lib/pgsql/openshift-custom-recovery.conf 2>/dev/null)"
check_contains "primary_conninfo points at $PRIMARY" "host=${PRIMARY}.postgresql-hl" "$CONNINFO"
check_contains "primary_conninfo uses the replication user" "user=$REPL_USER" "$CONNINFO"

# The replica's walreceiver must exist on the primary
check_eq "the primary sees 1 replica streaming" "1" "$(streaming_count "$PRIMARY")"
check_eq "replica application_name" "walreceiver" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT application_name FROM pg_stat_replication LIMIT 1")"

t_summary
