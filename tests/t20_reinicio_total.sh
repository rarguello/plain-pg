#!/usr/bin/env bash
# t20 -- Tras un failover, recrear LOS DOS pods a la vez deja los roles
#        correctos. Es la prueba del cambio a podManagementPolicy: Parallel
#        (con OrderedReady esto seria un deadlock).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t20 reinicio total tras failover"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
streaming() { [ "$(streaming_count "$1")" = "1" ]; }

echo "  (failover a $REPLICA)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$REPLICA" >/dev/null 2>&1 || c_fail "el failover fallo"
wait_for 300 "$REPLICA es primary" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"

echo "  (recreando AMBOS pods a la vez)"
oc -n "$NS" delete pod "$PRIMARY" "$REPLICA" >/dev/null 2>&1

wait_for 420 "$REPLICA vuelve Ready (como primary)" pod_ready "$REPLICA"
wait_for 420 "$PRIMARY vuelve Ready (como replica)" pod_ready "$PRIMARY"
check_eq "$REPLICA sigue siendo primary" "f" "$(pod_in_recovery "$REPLICA")"
check_eq "$PRIMARY volvio como standby" "t" "$(pod_in_recovery "$PRIMARY")"
wait_for 180 "la replicacion se restablece tras el reinicio total" streaming "$REPLICA"

echo "  (failback)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$PRIMARY" >/dev/null 2>&1 || c_fail "el failback fallo"
check_eq "$PRIMARY vuelve a ser primary" "f" "$(pod_in_recovery "$PRIMARY")"
wait_for 300 "$REPLICA vuelve a ser standby" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$REPLICA vuelve a ser standby" "t" "$(pod_in_recovery "$REPLICA")"

t_summary
