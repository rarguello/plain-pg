#!/usr/bin/env bash
#
# reseed-replica.sh -- forces a full re-seed (pg_basebackup) of a replica,
# deleting its PVC. Useful when replication broke (e.g. the primary recycled WAL
# that the replica needed) or PGDATA became corrupted.
#
# Usage:
#   ./scripts/reseed-replica.sh postgresql-1
#
# LIMITATION: it only works with the HIGHEST ordinal, because scaling the
# StatefulSet down deletes that pod first (and releases its PVC).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

POD="${1:-}"
if [ -z "$POD" ]; then
  echo "usage: $0 <replica-pod>" >&2
  exit 1
fi

ORD="${POD##*-}"
REPLICAS="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}')"
LAST=$((REPLICAS - 1))

# An HPA owns `replicas`: it would undo the scale-down below and could even
# recreate the pod while its PVC is being deleted.
if oc -n "$NS" get hpa postgresql-read >/dev/null 2>&1; then
  echo "ERROR: an HPA (postgresql-read) owns the replica count; it would undo the scale-down." >&2
  echo "       Delete or suspend it first:  oc -n $NS delete hpa postgresql-read" >&2
  exit 1
fi

if [ "$ORD" != "$LAST" ]; then
  echo "ERROR: only re-seeding the highest ordinal ($LAST) is supported." >&2
  echo "       For $POD: re-seed $((LAST)) and then scale back up, or recreate the STS." >&2
  exit 1
fi

echo "Scaling postgres to $LAST to release the pod/PVC of $POD"
oc -n "$NS" scale statefulset postgresql --replicas="$LAST"
oc -n "$NS" wait --for=delete "pod/$POD" --timeout=300s

echo "Deleting PVC pgdata-$POD"
oc -n "$NS" delete pvc "pgdata-$POD" --ignore-not-found

echo "Scaling postgres back to $REPLICAS"
oc -n "$NS" scale statefulset postgresql --replicas="$REPLICAS"
if ! wait_db_ready "$REPLICAS"; then
  echo "ERROR: the pods did not become Ready in time" >&2
  exit 1
fi

echo "Re-seed complete. Verify with: ./scripts/verify-replication.sh"
