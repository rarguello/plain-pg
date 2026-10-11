#!/usr/bin/env bash
#
# teardown.sh -- destruye el laboratorio.
#
# Uso:
#   ./scripts/teardown.sh          # borra recursos + PVCs + Secret (mantiene el namespace)
#   ./scripts/teardown.sh --all    # borra el namespace completo
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NS="${NAMESPACE:-pg-ha-lab}"
OVERLAY="${1:-manifests/overlays/lab}"

if [ "${1:-}" = "--all" ] || [ "${2:-}" = "--all" ]; then
  echo "==> Borrando el namespace $NS (esto elimina TODO, incluidos los PVCs)"
  oc delete namespace "$NS" --ignore-not-found --wait=true
  echo "==> Listo"
  exit 0
fi

echo "==> Borrando recursos de $OVERLAY"
oc delete -k "$OVERLAY" --ignore-not-found

echo "==> Borrando PVCs (el StatefulSet no los borra solo)"
oc -n "$NS" delete pvc -l app.kubernetes.io/instance=postgres --ignore-not-found

echo "==> Borrando el Secret"
oc -n "$NS" delete secret postgres-credentials --ignore-not-found

echo "==> Listo (namespace $NS conservado)"
