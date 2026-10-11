#!/usr/bin/env bash
#
# failover-manual.sh -- promueve una replica a primary, paso a paso.
#
# Uso:
#   ./scripts/failover-manual.sh              # elige la primera replica
#   ./scripts/failover-manual.sh postgres-1   # candidato explicito
#   FORCE=1 ./scripts/failover-manual.sh      # sin confirmacion
#
# Secuencia (promover primero, para no destruir datos del ex-primary hasta que
# el nuevo primary este confirmado):
#   1. PRIMARY_POD=<candidato> en el ConfigMap de rol
#   2. reapuntar Services -rw -> candidato, -ro -> ex-primary
#   3. recrear el pod candidato (arranca como primary)
#   4. esperar confirmacion (pg_is_in_recovery() = f)
#   5. recrear el pod ex-primary (se re-siembra como replica)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_credentials

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

echo "[1/5] ConfigMap postgres-role: PRIMARY_POD=$CANDIDATE"
oc -n "$NS" patch configmap postgres-role --type merge \
  -p "{\"data\":{\"PRIMARY_POD\":\"$CANDIDATE\"}}"

echo "[2/5] Services: -rw -> $CANDIDATE, -ro -> $OLD"
oc -n "$NS" patch svc postgres-rw \
  -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$CANDIDATE\"}}}"
oc -n "$NS" patch svc postgres-ro \
  -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$OLD\"}}}"

echo "[3/5] Recreando el pod $CANDIDATE para que se promueva"
oc -n "$NS" delete pod "$CANDIDATE"

echo "[4/5] Esperando a que $CANDIDATE sea primary..."
OK=0
for _ in $(seq 1 60); do
  if [ "$(pod_in_recovery "$CANDIDATE")" = "f" ]; then OK=1; break; fi
  sleep 5
done
if [ "$OK" != "1" ]; then
  echo "ERROR: $CANDIDATE no llego a primary. Estado: $(pod_in_recovery "$CANDIDATE")" >&2
  exit 1
fi
echo "      $CANDIDATE es PRIMARY."

echo "[5/5] Recreando el ex-primary $OLD (se re-siembra como replica)"
oc -n "$NS" delete pod "$OLD"

echo
echo "Failover completado: primary=$CANDIDATE  replica=$OLD"
echo "Verifica con: ./scripts/verify-replication.sh"
