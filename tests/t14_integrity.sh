#!/usr/bin/env bash
# t14 -- Integrity under load: lots of data, no divergence between primary and
#        replica (comparison by checksum).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t14 integrity under load"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
N=5000

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_load(id bigserial PRIMARY KEY, v text, n int)" >/dev/null 2>&1

echo "  (inserting $N rows on the primary)"
pod_psql "$PRIMARY" -q -c \
  "INSERT INTO t_load(v, n) SELECT 'load-'||g, g FROM generate_series(1, $N) g" >/dev/null 2>&1

count_is() { [ "$(pod_psql "$1" -tAc 'SELECT count(*) FROM t_load' 2>/dev/null)" = "$2" ]; }
wait_for 120 "the replica reaches $N rows" count_is "$REPLICA" "$N"

SUM_P="$(pod_psql "$PRIMARY" -tAc "SELECT md5(string_agg(id||':'||v||':'||n, ',' ORDER BY id)) FROM t_load")"
SUM_R="$(pod_psql "$REPLICA" -tAc "SELECT md5(string_agg(id||':'||v||':'||n, ',' ORDER BY id)) FROM t_load")"
check_eq "the data checksum matches on primary and replica" "$SUM_P" "$SUM_R"

check_eq "the lag returns to 0 after the load" "0" \
  "$(pod_psql_admin "$PRIMARY" -tAc \
     "SELECT COALESCE(sum(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),0)::bigint FROM pg_stat_replication")"

# Control write after the load
MARK="post-load-$(date +%s)"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_load(v, n) VALUES ('$MARK', 0)" >/dev/null 2>&1
has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_load WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
wait_for 30 "the write after the load replicates" has_row "$REPLICA" "$MARK"

# Cleanup so as not to accumulate data
pod_psql "$PRIMARY" -q -c "DROP TABLE IF EXISTS t_load" >/dev/null 2>&1 || true

t_summary
