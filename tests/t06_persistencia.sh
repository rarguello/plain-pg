#!/usr/bin/env bash
# t06 -- Persistencia y auto-recuperacion: reiniciar pods no pierde datos ni
#        re-siembra la replica innecesariamente.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t06 persistencia y reinicios"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_persist(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="persist-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_persist(v) VALUES ('$MARK')" >/dev/null 2>&1

has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_persist WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
streaming() { [ "$(streaming_count "$1")" = "1" ]; }

wait_for 30 "la fila '$MARK' se replica" has_row "$REPLICA" "$MARK"

# --- Reinicio de la REPLICA ---
PVC_UID_BEFORE="$(oc -n "$NS" get pvc "pgdata-$REPLICA" -o jsonpath='{.metadata.uid}')"
echo "  (reiniciando la replica $REPLICA)"
oc -n "$NS" delete pod "$REPLICA" >/dev/null 2>&1
wait_for 180 "la replica vuelve Ready" pod_ready "$REPLICA"
check_eq "la replica conserva su PVC (mismo UID)" "$PVC_UID_BEFORE" \
  "$(oc -n "$NS" get pvc "pgdata-$REPLICA" -o jsonpath='{.metadata.uid}')"
check "la replica NO re-sembro (sin 'vaciando PGDATA' en logs)" \
  bash -c "! oc -n $NS logs $REPLICA 2>/dev/null | grep -q 'vaciando PGDATA'"
check_eq "la replica sigue siendo standby tras reiniciar" "t" "$(pod_in_recovery "$REPLICA")"
check "la fila '$MARK' sigue en la replica" has_row "$REPLICA" "$MARK"
wait_for 90 "la replicacion se reanuda tras reiniciar la replica" streaming "$PRIMARY"

# --- Reinicio del PRIMARY ---
echo "  (reiniciando el primary $PRIMARY)"
oc -n "$NS" delete pod "$PRIMARY" >/dev/null 2>&1
wait_for 240 "el primary vuelve Ready" pod_ready "$PRIMARY"
check_eq "el primary sigue siendo primary" "f" "$(pod_in_recovery "$PRIMARY")"
check "la fila '$MARK' sigue en el primary" has_row "$PRIMARY" "$MARK"
wait_for 120 "la replicacion se reanuda tras reiniciar el primary" streaming "$PRIMARY"

t_summary
