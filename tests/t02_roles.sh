#!/usr/bin/env bash
# t02 -- Roles: quien es primary y quien replica, y su coherencia en disco.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t02 roles de los pods"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

check_eq "el ConfigMap declara postgres-0 como primary" "postgres-0" "$PRIMARY"
check_eq "el primary no esta en recovery" "f" "$(pod_in_recovery "$PRIMARY")"
check_eq "la replica esta en recovery" "t" "$(pod_in_recovery "$REPLICA")"

check "el primary NO tiene standby.signal" \
  bash -c "oc -n $NS exec $PRIMARY -- test ! -e $PGDATA_PATH/standby.signal"
check "el primary NO tiene recovery.signal" \
  bash -c "oc -n $NS exec $PRIMARY -- test ! -e $PGDATA_PATH/recovery.signal"
check "la replica SI tiene standby.signal" \
  bash -c "oc -n $NS exec $REPLICA -- test -e $PGDATA_PATH/standby.signal"
check "la replica NO tiene recovery.signal" \
  bash -c "oc -n $NS exec $REPLICA -- test ! -e $PGDATA_PATH/recovery.signal"

# primary_conninfo de la replica apunta al primary declarado
CONNINFO="$(oc -n "$NS" exec "$REPLICA" -- cat /var/lib/pgsql/openshift-custom-recovery.conf 2>/dev/null)"
check_contains "primary_conninfo apunta a $PRIMARY" "host=${PRIMARY}.postgres-hl" "$CONNINFO"
check_contains "primary_conninfo usa el usuario de replicacion" "user=$REPL_USER" "$CONNINFO"

# En el primary debe existir el walreceiver de la replica
check_eq "el primary ve 1 replica en streaming" "1" "$(streaming_count "$PRIMARY")"
check_eq "application_name de la replica" "walreceiver" \
  "$(pod_psql_admin "$PRIMARY" -tAc "SELECT application_name FROM pg_stat_replication LIMIT 1")"

t_summary
