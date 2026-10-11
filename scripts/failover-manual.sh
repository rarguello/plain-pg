#!/usr/bin/env bash
#
# failover-manual.sh -- promueve una replica a primary.
#
# Uso:
#   ./scripts/failover-manual.sh              # elige la primera replica
#   ./scripts/failover-manual.sh postgres-1   # candidato explicito
#   FORCE=1 ./scripts/failover-manual.sh      # sin confirmacion
#
# Orden (fencing primero, para no dejar nunca dos primaries a la vez):
#   1. Desactiva el failover automatico mientras dura la operacion (si estaba
#      activo) para que el CronJob no interfiera.
#   2. ConfigMap PRIMARY_POD=<candidato>.
#   3. Services: -rw -> candidato, -ro -> ex-primary.
#   4. FENCING verificable del ex-primary: se lo borra y se espera a que el
#      objeto del pod cambie de UID (o desaparezca). Si no se puede confirmar,
#      se revierte todo y no se promueve.
#   5. Recrea el pod candidato -> se promueve.
#   6. Espera a confirmar. Si no promueve, NO se revierte (el ex-primary ya
#      esta aislado): se avisa fuerte y queda para intervencion manual.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_credentials

FENCE_TIMEOUT="${FENCE_TIMEOUT:-120}"

OLD="$(primary_pod)"
CANDIDATE="${1:-}"
if [ -z "$CANDIDATE" ]; then
  CANDIDATE="$(replica_pods | head -1)"
fi

if [ -z "$CANDIDATE" ]; then
  echo "ERROR: no hay replica candidata." >&2
  exit 1
fi
if [ "$CANDIDATE" = "$OLD" ]; then
  echo "ERROR: el candidato ($CANDIDATE) ya es el primary declarado." >&2
  exit 1
fi

echo "Failover: $OLD (primary) -> $CANDIDATE (replica)"
if [ "${FORCE:-0}" != "1" ]; then
  read -r -p "¿Continuar? [y/N] " ans
  [ "$ans" = "y" ] || { echo "Cancelado."; exit 1; }
fi

set_cm_primary() {
  oc -n "$NS" patch configmap postgres-role --type merge \
    -p "{\"data\":{\"PRIMARY_POD\":\"$1\"}}" >/dev/null
}
set_services() {   # $1 = primary, $2 = replica
  oc -n "$NS" patch svc postgres-rw \
    -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$1\"}}}" >/dev/null
  oc -n "$NS" patch svc postgres-ro \
    -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$2\"}}}" >/dev/null
}
pod_uid() { oc -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }
fence_pod() {
  local pod="$1" uid newuid t=0
  uid="$(pod_uid "$pod")"
  if [ -z "$uid" ]; then echo "      $pod ya no existe"; return 0; fi
  echo "      borrando $pod (uid ${uid:0:8}) y esperando su terminacion"
  oc -n "$NS" delete pod "$pod" --wait=false >/dev/null
  while [ "$t" -lt "$FENCE_TIMEOUT" ]; do
    sleep 3; t=$((t + 3))
    newuid="$(pod_uid "$pod")"
    if [ -z "$newuid" ] || [ "$newuid" != "$uid" ]; then
      echo "      $pod terminado (uid nuevo ${newuid:0:8})"
      return 0
    fi
  done
  return 1
}

# 1) Evitar que el failover automatico interfiera.
AUTO_BEFORE="$(cm_value AUTO_FAILOVER || true)"
if [ "$AUTO_BEFORE" = "true" ]; then
  echo "[0/5] Desactivando AUTO_FAILOVER mientras dura la operacion"
  oc -n "$NS" patch configmap postgres-role --type merge \
    -p '{"data":{"AUTO_FAILOVER":"false"}}' >/dev/null
fi

echo "[1/5] ConfigMap postgres-role: PRIMARY_POD=$CANDIDATE"
set_cm_primary "$CANDIDATE"

echo "[2/5] Services: -rw -> $CANDIDATE, -ro -> $OLD"
if ! set_services "$CANDIDATE" "$OLD"; then
  echo "ERROR: no se pudieron reapuntar los Services; revirtiendo el ConfigMap" >&2
  set_cm_primary "$OLD"
  exit 1
fi

echo "[3/5] Fencing del ex-primary $OLD"
if ! fence_pod "$OLD"; then
  echo "ERROR: no se pudo confirmar el aislamiento de $OLD; REVIRTIENDO" >&2
  set_cm_primary "$OLD"
  set_services "$OLD" "$CANDIDATE"
  exit 1
fi

echo "[4/5] Recreando el pod $CANDIDATE para que se promueva"
oc -n "$NS" delete pod "$CANDIDATE" >/dev/null

echo "[5/5] Esperando a que $CANDIDATE sea primary..."
OK=0
for _ in $(seq 1 60); do
  if [ "$(pod_in_recovery "$CANDIDATE")" = "f" ]; then OK=1; break; fi
  sleep 5
done

if [ "$OK" != "1" ]; then
  echo "CRITICO: $CANDIDATE no llego a primary (estado: '$(pod_in_recovery "$CANDIDATE")')." >&2
  echo "CRITICO: el ConfigMap ya lo declara primary y el ex-primary esta aislado." >&2
  echo "CRITICO: NO se revierte. Revisar los pods y terminar la promocion a mano." >&2
  exit 1
fi

if [ "$AUTO_BEFORE" = "true" ]; then
  echo "      reactivando AUTO_FAILOVER"
  oc -n "$NS" patch configmap postgres-role --type merge \
    -p '{"data":{"AUTO_FAILOVER":"true"}}' >/dev/null
fi

echo
echo "Failover completado: primary=$CANDIDATE  replica=$OLD (se re-siembra sola)"
echo "Verifica con: ./scripts/verify-replication.sh"
