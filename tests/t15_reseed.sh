#!/usr/bin/env bash
# t15 -- Recuperacion de una replica: scripts/reseed-replica.sh la vuelve a
#        sembrar desde cero y queda replicando.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t15 re-siembra de una replica"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
streaming() { [ "$(streaming_count "$PRIMARY")" = "1" ]; }

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_reseed(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="rs-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_reseed(v) VALUES ('$MARK')" >/dev/null 2>&1
has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_reseed WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
wait_for 30 "los datos llegan a la replica antes de re-sembrar" has_row "$REPLICA" "$MARK"

PVC_UID_BEFORE="$(oc -n "$NS" get pvc "pgdata-$REPLICA" -o jsonpath='{.metadata.uid}')"

echo "  (re-sembrando $REPLICA)"
if ! "$ROOT_DIR/scripts/reseed-replica.sh" "$REPLICA" >/dev/null 2>&1; then
  c_fail "reseed-replica.sh fallo"
fi

wait_for 300 "$REPLICA vuelve Ready" pod_ready "$REPLICA"
check_ne "el PVC de la replica fue recreado (UID distinto)" "$PVC_UID_BEFORE" \
  "$(oc -n "$NS" get pvc "pgdata-$REPLICA" -o jsonpath='{.metadata.uid}')"
check_eq "$REPLICA es standby tras la re-siembra" "t" "$(pod_in_recovery "$REPLICA")"
check "los datos siguen en la replica re-sembrada" has_row "$REPLICA" "$MARK"
check "la re-siembra quedo registrada en los logs" \
  bash -c "oc -n $NS logs $REPLICA 2>/dev/null | grep -q 'pg_basebackup'"
wait_for 120 "la replicacion se restablece" streaming

t_summary
