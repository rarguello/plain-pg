#!/usr/bin/env bash
#
# deploy.sh -- despliega pg-ha de forma idempotente.
#
# Uso:
#   ./scripts/deploy.sh                          # overlay completo (con failover automatico)
#   ./scripts/deploy.sh manifests/overlays/lab-manual   # solo failover manual
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

OVERLAY="${1:-manifests/overlays/lab}"
NS="${NAMESPACE:-pg-ha-lab}"

echo "==> Render previo (kustomize)"
oc kustomize "$OVERLAY" >/dev/null

echo "==> Aplicando $OVERLAY"
oc apply -k "$OVERLAY"

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
