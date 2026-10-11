#!/usr/bin/env bash
# t11 -- Teardown y re-despliegue desde cero (prueba el ciclo de vida completo).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t11 teardown y re-despliegue"

echo "  (teardown)"
"$ROOT_DIR/scripts/teardown.sh" >/dev/null 2>&1

check "no quedan pods de la BD" \
  bash -c "! oc -n $NS get pods -l app.kubernetes.io/component=database 2>/dev/null | grep -q postgres-0"
check "no quedan PVCs de la BD" \
  bash -c "! oc -n $NS get pvc -l app.kubernetes.io/instance=postgres 2>/dev/null | grep -q pgdata-"
check "no queda el Secret" \
  bash -c "! oc -n $NS get secret postgres-credentials >/dev/null 2>&1"
check "el teardown normal NO borra el namespace" oc get namespace "$NS"

echo "  (re-despliegue desde cero)"
if NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" >/dev/null 2>&1; then
  c_ok "deploy.sh completa el despliegue"
else
  c_fail "deploy.sh fallo en el re-despliegue"
fi

wait_for 300 "postgres-0 Ready tras el re-despliegue" pod_ready postgres-0
wait_for 300 "postgres-1 Ready tras el re-despliegue" pod_ready postgres-1
check_eq "postgres-0 es primary tras el re-despliegue" "f" "$(pod_in_recovery postgres-0)"
check_eq "postgres-1 es standby tras el re-despliegue" "t" "$(pod_in_recovery postgres-1)"
check_eq "replicacion activa tras el re-despliegue" "1" "$(streaming_count postgres-0)"

# El PVC nuevo debe estar Bound
check_eq "el PVC de postgres-0 esta Bound" "Bound" \
  "$(oc -n "$NS" get pvc pgdata-postgres-0 -o jsonpath='{.status.phase}' 2>/dev/null)"

t_summary
