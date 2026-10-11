#!/usr/bin/env bash
#
# deploy.sh -- deploys plain-pg idempotently.
#
# Usage:
#   ./scripts/deploy.sh                          # full overlay (with automatic failover)
#   ./scripts/deploy.sh manifests/overlays/lab-manual   # manual failover only
#   ./scripts/deploy.sh --reset-role             # returns to the initial state
#                                                # (PRIMARY_POD=postgresql-0)
#
# IMPORTANT: by default it PRESERVES the operational failover state WITHOUT
# creating an inconsistent window. If the current primary is not postgresql-0, the
# manifest is rendered and the role/selectors are rewritten BEFORE applying it
# (needs python3 + pyyaml). Thus `oc apply` never gets to set the old role.
#
# `--reset-role` is only allowed if the current primary is ALREADY postgresql-0;
# if there was a failover, the failback must be done first:
#   ./scripts/failover-manual.sh postgresql-0
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

# Reads the current operational state into RP/RRW/RRO.
read_state() {
  RP="$(oc -n "$NS" get cm postgresql-role -o jsonpath='{.data.PRIMARY_POD}' 2>/dev/null || true)"
  RRW="$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null || true)"
  RRO="$(oc -n "$NS" get svc postgresql-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null || true)"
}

echo "==> Pre-render (kustomize)"
oc kustomize "$OVERLAY" >/dev/null

read_state
CUR_PRIMARY="$RP"; CUR_RW="$RRW"; CUR_RO="$RRO"

if [ -n "$CUR_PRIMARY" ] && { [ -z "$CUR_RW" ] || [ -z "$CUR_RO" ]; }; then
  echo "ERROR: could not read the Service selectors; aborting." >&2
  exit 1
fi

if [ "$RESET_ROLE" = "1" ] && [ -n "$CUR_PRIMARY" ] && [ "$CUR_PRIMARY" != "postgresql-0" ]; then
  echo "ERROR: --reset-role would return the role to postgresql-0, but the current primary is $CUR_PRIMARY." >&2
  echo "       Do the failback first: ./scripts/failover-manual.sh postgresql-0" >&2
  exit 1
fi

if [ "$RESET_ROLE" != "1" ] && [ -n "$CUR_PRIMARY" ] && [ "$CUR_PRIMARY" != "postgresql-0" ]; then
  if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "ERROR: to re-apply after a failover, python3 + pyyaml are needed" >&2
    echo "       (or do the failback first with ./scripts/failover-manual.sh postgresql-0)" >&2
    exit 1
  fi
  echo "==> Preserving the failover state (primary=$CUR_PRIMARY, rw=$CUR_RW, ro=$CUR_RO)"
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
    if kind == "ConfigMap" and name == "postgresql-role":
        doc.setdefault("data", {})["PRIMARY_POD"] = primary
    elif kind == "Service" and name in ("postgresql-rw", "postgresql-ro"):
        want = rw if name == "postgresql-rw" else ro
        if want:
            doc.setdefault("spec", {}).setdefault("selector", {})[
                "statefulset.kubernetes.io/pod-name"
            ] = want
with open(path, "w") as fh:
    yaml.safe_dump_all(docs, fh, default_flow_style=False, sort_keys=False,
                       width=10**9)
PY

  # Re-read right before applying: if a failover happened while the render was
  # being prepared, it aborts instead of overwriting it.
  read_state
  if [ "$RP" != "$CUR_PRIMARY" ] || [ "$RRW" != "$CUR_RW" ] || [ "$RRO" != "$CUR_RO" ]; then
    echo "ERROR: the failover state changed while the deploy was being prepared; retry." >&2
    rm -f "$TMP"
    exit 1
  fi

  echo "==> Applying $OVERLAY (with the role preserved)"
  oc apply -f "$TMP"
  rm -f "$TMP"
else
  echo "==> Applying $OVERLAY"
  oc apply -k "$OVERLAY"
fi

# Post-check: if a failover happened during the apply, warn loudly (it cannot
# be fully avoided without a shared lock: do not run deploy.sh and a failover at
# the same time).
if [ -n "$CUR_PRIMARY" ]; then
  read_state
  if [ "$RP" != "$CUR_PRIMARY" ] || [ "$RRW" != "$CUR_RW" ] || [ "$RRO" != "$CUR_RO" ]; then
    echo "WARNING: the failover state changed during the deploy (concurrent failover?)" >&2
    echo "  expected: CM=$CUR_PRIMARY rw=$CUR_RW ro=$CUR_RO" >&2
    echo "  now:      CM=$RP rw=$RRW ro=$RRO" >&2
  fi
fi

echo "==> Credentials"
NAMESPACE="$NS" "$ROOT_DIR/scripts/generate-secret.sh"

echo "==> Waiting for the PostgreSQL pods to be Ready"
echo "    (the replica runs pg_basebackup, it may take a while)"
if ! wait_db_ready; then
  echo "ERROR: the pods did not become Ready in time" >&2
  oc -n "$NS" get pods,pvc >&2
  exit 1
fi

echo
echo "==> Status"
oc -n "$NS" get pods,pvc,svc
echo
echo "Done. Verify replication with:  ./scripts/verify-replication.sh"
