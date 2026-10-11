#!/usr/bin/env bash
# t13 -- Escalado: agregar una segunda replica la siembra y la deja replicando.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t13 escalado de replicas"

PRIMARY="$(primary_pod)"
streaming() { [ "$(streaming_count "$PRIMARY")" = "$1" ]; }

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_scale(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="sc-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_scale(v) VALUES ('$MARK')" >/dev/null 2>&1

echo "  (escalando a 3 pods)"
oc -n "$NS" scale statefulset postgres --replicas=3 >/dev/null
wait_for 420 "postgres-2 queda Ready" pod_ready postgres-2
check_eq "postgres-2 es standby" "t" "$(pod_in_recovery postgres-2)"
check_eq "el primary ve 2 replicas en streaming" "2" "$(streaming_count "$PRIMARY")"
has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_scale WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
check "postgres-2 recibio los datos existentes" has_row postgres-2 "$MARK"

# El Service -rw sigue apuntando solo al primary
check_eq "postgres-rw sigue en el primary" \
  "$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.status.podIP}')" \
  "$(oc -n "$NS" get endpoints postgres-rw -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"

echo "  (volviendo a 2 pods)"
oc -n "$NS" scale statefulset postgres --replicas=2 >/dev/null
wait_for 180 "postgres-2 se elimina" bash -c "! oc -n $NS get pod postgres-2 >/dev/null 2>&1"
check "el PVC de postgres-2 queda huerfano (comportamiento esperado)" \
  oc -n "$NS" get pvc pgdata-postgres-2
wait_for 120 "queda 1 replica en streaming" streaming 1

# Limpieza del PVC huerfano
oc -n "$NS" delete pvc pgdata-postgres-2 --ignore-not-found >/dev/null 2>&1 || true

t_summary
