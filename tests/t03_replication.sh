#!/usr/bin/env bash
# t03 -- Real streaming replication: state, lag and end-to-end data test.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t03 streaming replication"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

STATE="$(pod_psql_admin "$PRIMARY" -tAc "SELECT state FROM pg_stat_replication LIMIT 1")"
check_eq "the replica is in 'streaming' state" "streaming" "$STATE"

SYNC="$(pod_psql_admin "$PRIMARY" -tAc "SELECT sync_state FROM pg_stat_replication LIMIT 1")"
check_match "sync_state is async or sync" "^(async|sync|potential)$" "$SYNC"

LAG="$(pod_psql_admin "$PRIMARY" -tAc \
  "SELECT COALESCE(sum(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),0)::bigint FROM pg_stat_replication")"
check_eq "the replay lag is 0 bytes" "0" "$LAG"

# End-to-end data test: write on the primary, read on the replica.
pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_repl(id bigserial PRIMARY KEY, v text, ts timestamptz DEFAULT now())" \
  >/dev/null 2>&1
MARK="repl-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_repl(v) VALUES ('$MARK')" >/dev/null 2>&1

has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_repl WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
wait_for 30 "row '$MARK' appears on the replica" has_row "$REPLICA" "$MARK"
check "row '$MARK' is on the primary" has_row "$PRIMARY" "$MARK"

# The replica is read-only
write_fails() { ! pod_psql "$1" -q -c "INSERT INTO t_repl(v) VALUES ('nope-$RANDOM')" >/dev/null 2>&1; }
check "the replica REJECTS writes (read-only)" write_fails "$REPLICA"

# A SELECT on the replica does not block and returns data
CNT="$(pod_psql "$REPLICA" -tAc 'SELECT count(*) FROM t_repl')"
check "the replica can read the replicated table" bash -c "[ ${CNT:-0} -ge 1 ]"

t_summary
