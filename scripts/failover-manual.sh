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
#   0. Desactiva el failover automatico mientras dura la operacion (si estaba
#      activo) para que el CronJob no interfiera.
#   1. ConfigMap PRIMARY_POD=<candidato>, con control de resourceVersion.
#   2. Services: -rw -> candidato, -ro -> ex-primary.
#   3. FENCING verificable del ex-primary: se lo borra y se espera a confirmar
#      que el pod desaparecio o cambio de UID. Un error de API (distinto de
#      "no existe") aborta y revierte.
#   4. Recrea el pod candidato -> se promueve.
#   5. Espera a confirmar. Si no promueve, NO se revierte (el ex-primary ya
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

# --- helpers ---------------------------------------------------------------
set_cm_primary() {   # $1 = pod, $2 = resourceVersion (opcional)
  local body
  if [ -n "${2:-}" ]; then
    body="{\"metadata\":{\"resourceVersion\":\"$2\"},\"data\":{\"PRIMARY_POD\":\"$1\"}}"
  else
    body="{\"data\":{\"PRIMARY_POD\":\"$1\"}}"
  fi
  oc -n "$NS" patch configmap postgres-role --type merge -p "$body" >/dev/null
}
set_services() {   # $1 = primary, $2 = replica; intenta ambos
  local ok=0
  oc -n "$NS" patch svc postgres-rw \
    -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$1\"}}}" >/dev/null || ok=1
  oc -n "$NS" patch svc postgres-ro \
    -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$2\"}}}" >/dev/null || ok=1
  return "$ok"
}
svc_pod() { oc -n "$NS" get svc "$1" -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null || true; }
restore_state() {   # $1 = primary, $2 = replica
  set_cm_primary "$1" || true
  set_services "$1" "$2" || true
  local cm rw ro
  cm="$(cm_value PRIMARY_POD || true)"
  rw="$(svc_pod postgres-rw)"
  ro="$(svc_pod postgres-ro)"
  if [ "$cm" != "$1" ] || [ "$rw" != "$1" ] || [ "$ro" != "$2" ]; then
    echo "CRITICO: estado inconsistente tras revertir (CM=$cm rw=$rw ro=$ro)" >&2
    return 1
  fi
  # El rol real de PostgreSQL tambien debe estar bien.
  if [ "$(pod_in_recovery "$1")" != "f" ]; then
    echo "CRITICO: tras revertir, $1 NO responde como primary. Intervencion requerida." >&2
    return 1
  fi
  return 0
}
pod_state() {   # "gone" | "uid:<uid>" | "error:<msg>"
  local out rc
  out="$(oc -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}' 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then printf 'uid:%s' "$out"; return 0; fi
  case "$out" in
    *NotFound*|*"not found"*) printf 'gone' ;;
    *) printf 'error:%s' "$out" ;;
  esac
}
fence_pod() {   # 0 = aislado; 1 = sin cambios (seguro revertir); 2 = borrado aceptado, sin confirmar
  local pod="$1" state uid t=0
  state="$(pod_state "$pod")"
  case "$state" in
    gone)    echo "      $pod ya no existe"; return 0 ;;
    error:*) echo "ERROR: no pude consultar $pod ($state)" >&2; return 1 ;;
    uid:*)   uid="${state#uid:}" ;;
  esac
  echo "      borrando $pod (uid ${uid:0:8}) y esperando su terminacion"
  if ! oc -n "$NS" delete pod "$pod" --wait=false >/dev/null; then
    echo "ERROR: no pude borrar $pod (sin cambios)" >&2; return 1
  fi
  while [ "$t" -lt "$FENCE_TIMEOUT" ]; do
    sleep 3; t=$((t + 3))
    state="$(pod_state "$pod")"
    case "$state" in
      gone)    echo "      $pod desaparecio"; return 0 ;;
      error:*) echo "ERROR: no pude confirmar la terminacion de $pod ($state)" >&2; return 2 ;;
      uid:*)   if [ "${state#uid:}" != "$uid" ]; then
                 echo "      $pod recreado (uid nuevo)"; return 0
               fi ;;
    esac
  done
  echo "ERROR: $pod no se termino en ${FENCE_TIMEOUT}s (borrado ya aceptado)" >&2
  return 2
}

# --- 1) Evitar que el failover automatico interfiera -----------------------
AUTO_BEFORE="$(cm_value AUTO_FAILOVER || true)"
if [ "$AUTO_BEFORE" = "true" ]; then
  echo "[0/5] Desactivando AUTO_FAILOVER mientras dura la operacion"
  oc -n "$NS" patch configmap postgres-role --type merge \
    -p '{"data":{"AUTO_FAILOVER":"false"}}' >/dev/null
fi

# --- 2) Declarar el candidato (concurrencia optimista) ---------------------
echo "[1/5] ConfigMap postgres-role: PRIMARY_POD=$CANDIDATE"
CM_RV="$(oc -n "$NS" get cm postgres-role -o jsonpath='{.metadata.resourceVersion}')"
if ! set_cm_primary "$CANDIDATE" "$CM_RV"; then
  echo "ERROR: no se pudo actualizar el ConfigMap (¿cambio el rol?); se aborta" >&2
  exit 1
fi

echo "[2/5] Services: -rw -> $CANDIDATE, -ro -> $OLD"
if ! set_services "$CANDIDATE" "$OLD"; then
  echo "ERROR: no se pudieron reapuntar los Services; revirtiendo" >&2
  restore_state "$OLD" "$CANDIDATE" || echo "CRITICO: reversion inconsistente" >&2
  exit 1
fi

echo "[3/5] Fencing del ex-primary $OLD"
FRC=0
fence_pod "$OLD" || FRC=$?
if [ "$FRC" -eq 1 ]; then
  echo "ERROR: no se pudo confirmar el aislamiento de $OLD (sin cambios); REVIRTIENDO" >&2
  restore_state "$OLD" "$CANDIDATE" || echo "CRITICO: reversion inconsistente" >&2
  exit 1
elif [ "$FRC" -eq 2 ]; then
  echo "CRITICO: el borrado de $OLD fue aceptado pero no se pudo confirmar su terminacion." >&2
  echo "CRITICO: NO se revierte (el pod pudo recrearse como replica). Intervencion requerida." >&2
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
