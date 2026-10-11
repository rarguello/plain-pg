#!/usr/bin/env bash
# t07 -- Failover MANUAL completo, ida y vuelta (failback).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t07 failover manual (ida y vuelta)"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_failover(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="fo-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_failover(v) VALUES ('$MARK')" >/dev/null 2>&1
has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_failover WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
streaming() { [ "$(streaming_count "$1")" = "1" ]; }
wait_for 30 "la fila '$MARK' se replica antes del failover" has_row "$REPLICA" "$MARK"

# --- FAILOVER ---
echo "  (ejecutando scripts/failover-manual.sh $REPLICA)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$REPLICA" || c_fail "el script de failover fallo"

check_eq "el ConfigMap declara $REPLICA como primary" "$REPLICA" "$(primary_pod)"
check_eq "$REPLICA es ahora primary" "f" "$(pod_in_recovery "$REPLICA")"
wait_for 300 "$PRIMARY se re-siembra como replica" bash -c "[ \"\$(oc -n $NS get pod $PRIMARY -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$PRIMARY es ahora standby" "t" "$(pod_in_recovery "$PRIMARY")"
check "los datos previos sobreviven en el nuevo primary" has_row "$REPLICA" "$MARK"
wait_for 180 "la replicacion corre en el nuevo sentido" streaming "$REPLICA"

IP_NEW="$(oc -n "$NS" get pod "$REPLICA" -o jsonpath='{.status.podIP}')"
check_eq "postgres-rw fue reapuntado al nuevo primary" "$IP_NEW" \
  "$(oc -n "$NS" get endpoints postgres-rw -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
IP_OLD="$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.status.podIP}')"
check_eq "postgres-ro fue reapuntado a la nueva replica" "$IP_OLD" \
  "$(oc -n "$NS" get endpoints postgres-ro -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"

# Reaplicar los manifiestos NO debe revertir el failover
echo "  (reaplicando manifiestos con $REPLICA como primary)"
NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" >/dev/null 2>&1 || c_fail "deploy.sh fallo tras el failover"
check_eq "deploy.sh preserva PRIMARY_POD=$REPLICA" "$REPLICA" "$(primary_pod)"
check_eq "deploy.sh preserva el selector de postgres-rw" "$REPLICA" \
  "$(oc -n "$NS" get svc postgres-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"
check_eq "deploy.sh preserva el selector de postgres-ro" "$PRIMARY" \
  "$(oc -n "$NS" get svc postgres-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"

# --- FAILBACK ---
echo "  (failback: promoviendo de vuelta $PRIMARY)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$PRIMARY" || c_fail "el failback fallo"
check_eq "el ConfigMap vuelve a declarar $PRIMARY" "$PRIMARY" "$(primary_pod)"
check_eq "$PRIMARY vuelve a ser primary" "f" "$(pod_in_recovery "$PRIMARY")"
wait_for 300 "$REPLICA vuelve a ser replica" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$REPLICA vuelve a ser standby" "t" "$(pod_in_recovery "$REPLICA")"
check "los datos sobreviven al failback" has_row "$PRIMARY" "$MARK"
wait_for 180 "la replicacion se restablece" streaming "$PRIMARY"

t_summary
