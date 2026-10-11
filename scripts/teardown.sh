#!/usr/bin/env bash
#
# teardown.sh -- destruye el laboratorio.
#
# Uso:
#   ./scripts/teardown.sh          # borra los recursos, PVCs y Secret
#                                  # (NO borra el namespace)
#   ./scripts/teardown.sh --all    # borra el namespace completo
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

if [ "${1:-}" = "--all" ]; then
  echo "==> Borrando el namespace $NS (elimina TODO, incluidos los PVCs)"
  oc delete namespace "$NS" --ignore-not-found --wait=true
  echo "==> Listo"
  exit 0
fi

if ! oc get namespace "$NS" >/dev/null 2>&1; then
  echo "==> El namespace $NS no existe; nada que borrar"
  exit 0
fi

# Se borra por etiqueta, no con `oc delete -k`, para NO incluir el objeto
# Namespace (que en el overlay es un recurso mas). El namespace solo se borra
# con --all.
echo "==> Borrando recursos del namespace $NS"
oc -n "$NS" delete \
  statefulset,service,configmap,cronjob,job,networkpolicy,serviceaccount,role,rolebinding \
  -l app.kubernetes.io/part-of=pg-ha --ignore-not-found

echo "==> Borrando PVCs (el StatefulSet no los borra solo)"
oc -n "$NS" delete pvc -l app.kubernetes.io/part-of=pg-ha --ignore-not-found

echo "==> Borrando el Secret"
oc -n "$NS" delete secret postgres-credentials --ignore-not-found

echo "==> Listo (namespace $NS conservado)"
