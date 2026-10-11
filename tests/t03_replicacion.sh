#!/usr/bin/env bash
# t03 -- Replicacion streaming real: estado, lag y prueba de datos end-to-end.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t03 replicacion streaming"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

STATE="$(pod_psql_admin "$PRIMARY" -tAc "SELECT state FROM pg_stat_replication LIMIT 1")"
check_eq "la replica esta en estado 'streaming'" "streaming" "$STATE"

SYNC="$(pod_psql_admin "$PRIMARY" -tAc "SELECT sync_state FROM pg_stat_replication LIMIT 1")"
check_match "sync_state es async o sync" "^(async|sync|potential)$" "$SYNC"

LAG="$(pod_psql_admin "$PRIMARY" -tAc \
  "SELECT COALESCE(sum(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),0)::bigint FROM pg_stat_replication")"
check_eq "el lag de replay es 0 bytes" "0" "$LAG"

# Prueba de datos end-to-end: escribir en el primary, leer en la replica.
pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_repl(id bigserial PRIMARY KEY, v text, ts timestamptz DEFAULT now())" \
  >/dev/null 2>&1
MARK="repl-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_repl(v) VALUES ('$MARK')" >/dev/null 2>&1

has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_repl WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
wait_for 30 "la fila '$MARK' aparece en la replica" has_row "$REPLICA" "$MARK"
check "la fila '$MARK' esta en el primary" has_row "$PRIMARY" "$MARK"

# La replica es read-only
write_fails() { ! pod_psql "$1" -q -c "INSERT INTO t_repl(v) VALUES ('nope-$RANDOM')" >/dev/null 2>&1; }
check "la replica RECHAZA escrituras (read-only)" write_fails "$REPLICA"

# Un SELECT en la replica no bloquea y devuelve datos
CNT="$(pod_psql "$REPLICA" -tAc 'SELECT count(*) FROM t_repl')"
check "la replica puede leer la tabla replicada" bash -c "[ ${CNT:-0} -ge 1 ]"

t_summary
