#!/usr/bin/env bash
#
# reseed-replica.sh -- fuerza una re-siembra completa (pg_basebackup) de una
# replica, borrando su PVC. Util cuando la replicacion se rompio (p.ej. el
# primary reciclo WAL que la replica necesitaba) o el PGDATA quedo corrupto.
#
# Uso:
#   ./scripts/reseed-replica.sh postgres-1
#
# LIMITACION: solo funciona con el ordinal MAS ALTO, porque escalar hacia
# abajo el StatefulSet elimina primero ese pod (y libera su PVC).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

POD="${1:-}"
if [ -z "$POD" ]; then
  echo "uso: $0 <pod-replica>" >&2
  exit 1
fi

ORD="${POD##*-}"
REPLICAS="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.replicas}')"
LAST=$((REPLICAS - 1))

if [ "$ORD" != "$LAST" ]; then
  echo "ERROR: solo se soporta re-sembrar el ordinal mas alto ($LAST)." >&2
  echo "       Para $POD: re-sembra $((LAST)) y luego vuelve a escalar, o recrea el STS." >&2
  exit 1
fi

echo "Escalando postgres a $LAST para liberar el pod/PVC de $POD"
oc -n "$NS" scale statefulset postgres --replicas="$LAST"
oc -n "$NS" wait --for=delete "pod/$POD" --timeout=300s

echo "Borrando PVC pgdata-$POD"
oc -n "$NS" delete pvc "pgdata-$POD" --ignore-not-found

echo "Escalando postgres de vuelta a $REPLICAS"
oc -n "$NS" scale statefulset postgres --replicas="$REPLICAS"
if ! wait_db_ready "$REPLICAS"; then
  echo "ERROR: los pods no quedaron Ready a tiempo" >&2
  exit 1
fi

echo "Re-siembra completada. Verifica con: ./scripts/verify-replication.sh"
