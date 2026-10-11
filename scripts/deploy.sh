#!/usr/bin/env bash
#
# deploy.sh -- despliega pg-ha de forma idempotente.
#
# Uso:
#   ./scripts/deploy.sh                          # overlay completo (con failover automatico)
#   ./scripts/deploy.sh manifests/overlays/lab-manual   # solo failover manual
#   ./scripts/deploy.sh --reset-role             # vuelve al estado inicial
#                                                # (PRIMARY_POD=postgres-0)
#
# IMPORTANTE: por defecto PRESERVA el estado operativo de failover SIN crear una
# ventana inconsistente. Si el primary actual no es postgres-0, el manifiesto se
# renderiza y se reescribe el rol/selectores ANTES de aplicarlo (necesita
# python3 + pyyaml). Asi `oc apply` nunca llega a poner el rol viejo.
#
# `--reset-role` solo se permite si el primary actual YA es postgres-0; si hubo
# un failover, primero hay que hacer el failback:
#   ./scripts/failover-manual.sh postgres-0
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

# Lee el estado operativo actual en RP/RRW/RRO.
read_state() {
  RP="$(oc -n "$NS" get cm postgres-role -o jsonpath='{.data.PRIMARY_POD}' 2>/dev/null || true)"
  RRW="$(oc -n "$NS" get svc postgres-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null || true)"
  RRO="$(oc -n "$NS" get svc postgres-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null || true)"
}

echo "==> Render previo (kustomize)"
oc kustomize "$OVERLAY" >/dev/null

read_state
CUR_PRIMARY="$RP"; CUR_RW="$RRW"; CUR_RO="$RRO"

if [ -n "$CUR_PRIMARY" ] && { [ -z "$CUR_RW" ] || [ -z "$CUR_RO" ]; }; then
  echo "ERROR: no pude leer los selectores de los Services; abortando." >&2
  exit 1
fi

if [ "$RESET_ROLE" = "1" ] && [ -n "$CUR_PRIMARY" ] && [ "$CUR_PRIMARY" != "postgres-0" ]; then
  echo "ERROR: --reset-role devolveria el rol a postgres-0, pero el primary actual es $CUR_PRIMARY." >&2
  echo "       Hace primero el failback: ./scripts/failover-manual.sh postgres-0" >&2
  exit 1
fi

if [ "$RESET_ROLE" != "1" ] && [ -n "$CUR_PRIMARY" ] && [ "$CUR_PRIMARY" != "postgres-0" ]; then
  if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "ERROR: para reaplicar despues de un failover se necesita python3 + pyyaml" >&2
    echo "       (o hacer el failback primero con ./scripts/failover-manual.sh postgres-0)" >&2
    exit 1
  fi
  echo "==> Preservando el estado de failover (primary=$CUR_PRIMARY, rw=$CUR_RW, ro=$CUR_RO)"
  TMP="$(mktemp)"
  oc kustomize "$OVERLAY" > "$TMP"
  python3 - "$TMP" "$CUR_PRIMARY" "$CUR_RW" "$CUR_RO" <<'PY'
import sys
import yaml

path, primary, rw, ro = sys.argv[1:5]
docs = [d for d in yaml.safe_load_all(open(path)) if d]
for doc in docs:
    kind = doc.get("kind")
    name = doc.get("metadata", {}).get("name")
    if kind == "ConfigMap" and name == "postgres-role":
        doc.setdefault("data", {})["PRIMARY_POD"] = primary
    elif kind == "Service" and name in ("postgres-rw", "postgres-ro"):
        want = rw if name == "postgres-rw" else ro
        if want:
            doc.setdefault("spec", {}).setdefault("selector", {})[
                "statefulset.kubernetes.io/pod-name"
            ] = want
with open(path, "w") as fh:
    yaml.safe_dump_all(docs, fh, default_flow_style=False, sort_keys=False,
                       width=10**9)
PY

  # Releer justo antes de aplicar: si un failover ocurrio mientras se preparaba
  # el render, se aborta en vez de pisarlo.
  read_state
  if [ "$RP" != "$CUR_PRIMARY" ] || [ "$RRW" != "$CUR_RW" ] || [ "$RRO" != "$CUR_RO" ]; then
    echo "ERROR: el estado de failover cambio mientras se preparaba el deploy; reintentar." >&2
    rm -f "$TMP"
    exit 1
  fi

  echo "==> Aplicando $OVERLAY (con el rol preservado)"
  oc apply -f "$TMP"
  rm -f "$TMP"
else
  echo "==> Aplicando $OVERLAY"
  oc apply -k "$OVERLAY"
fi

# Verificacion posterior: si un failover ocurrio durante el apply, avisar
# fuerte (no se puede evitar del todo sin un bloqueo compartido: no corras
# deploy.sh y un failover al mismo tiempo).
if [ -n "$CUR_PRIMARY" ]; then
  read_state
  if [ "$RP" != "$CUR_PRIMARY" ] || [ "$RRW" != "$CUR_RW" ] || [ "$RRO" != "$CUR_RO" ]; then
    echo "ADVERTENCIA: el estado de failover cambio durante el deploy (¿failover concurrente?)" >&2
    echo "  esperado: CM=$CUR_PRIMARY rw=$CUR_RW ro=$CUR_RO" >&2
    echo "  ahora:    CM=$RP rw=$RRW ro=$RRO" >&2
  fi
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
