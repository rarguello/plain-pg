#!/usr/bin/env bash
#
# deploy.sh -- despliega pg-ha de forma idempotente.
#
# Uso:
#   ./scripts/deploy.sh                          # overlay completo (con failover automatico)
#   ./scripts/deploy.sh manifests/overlays/lab-manual   # solo failover manual
#   ./scripts/deploy.sh --reset-role             # fuerza PRIMARY_POD=postgres-0
#                                                # y los selectores originales
#
# IMPORTANTE: por defecto PRESERVA el estado operativo de failover. Reaplicar
# los manifiestos no debe revertir un failover: si postgres-1 fue promovido, el
# ConfigMap y los selectores de los Services se dejan como estan (el manifiesto
# siempre declara postgres-0, que es solo el estado inicial).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

OVERLAY="manifests/overlays/lab"
RESET_ROLE=0
for arg in "$@"; do
  case "$arg" in
    --reset-role) RESET_ROLE=1 ;;
    *)            OVERLAY="$arg" ;;
  esac
done

echo "==> Render previo (kustomize)"
oc kustomize "$OVERLAY" >/dev/null

# --- Estado operativo actual (para no revertir un failover) ---
CUR_PRIMARY="$(oc -n "$NS" get cm postgres-role -o jsonpath='{.data.PRIMARY_POD}' 2>/dev/null || true)"
CUR_RW="$(oc -n "$NS" get svc postgres-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null || true)"
CUR_RO="$(oc -n "$NS" get svc postgres-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null || true)"

echo "==> Aplicando $OVERLAY"
oc apply -k "$OVERLAY"

if [ "$RESET_ROLE" != "1" ] && [ -n "$CUR_PRIMARY" ]; then
  oc -n "$NS" patch cm postgres-role --type merge \
    -p "{\"data\":{\"PRIMARY_POD\":\"$CUR_PRIMARY\"}}" >/dev/null
  [ -n "$CUR_RW" ] && oc -n "$NS" patch svc postgres-rw \
    -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$CUR_RW\"}}}" >/dev/null
  [ -n "$CUR_RO" ] && oc -n "$NS" patch svc postgres-ro \
    -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$CUR_RO\"}}}" >/dev/null
  [ "$CUR_PRIMARY" != "postgres-0" ] && \
    echo "==> Se preservo el estado de failover: PRIMARY_POD=$CUR_PRIMARY (rw=$CUR_RW, ro=$CUR_RO)"
fi

echo "==> Credenciales"
NAMESPACE="$NS" "$ROOT_DIR/scripts/generate-secret.sh"

echo "==> Esperando a que los pods de PostgreSQL esten Ready"
echo "    (la replica hace pg_basebackup, puede tardar)"
if ! wait_db_ready; then
  echo "ERROR: los pods no quedaron Ready a tiempo" >&2
  oc -n "$NS" get pods,pvc >&2
  exit 1
fi

echo
echo "==> Estado"
oc -n "$NS" get pods,pvc,svc
echo
echo "Listo. Verifica la replicacion con:  ./scripts/verify-replication.sh"
