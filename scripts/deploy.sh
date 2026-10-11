#!/usr/bin/env bash
#
# deploy.sh -- deploys plain-pg without clobbering live failover state.
#
# Usage:
#   ./scripts/deploy.sh                                 # lab (automatic failover)
#   ./scripts/deploy.sh manifests/overlays/lab-manual   # manual failover only
#
# A fresh install (no postgresql-role ConfigMap) applies the whole overlay.
#
# On an EXISTING deployment two kinds of live state are deliberately left
# untouched, because they are owned by the failover scripts and not by the
# static manifest:
#
#   * the postgresql-role ConfigMap (PRIMARY_POD, AUTO_FAILOVER, GRACE), and
#   * the postgresql-rw / postgresql-ro Services (their pod-name selectors).
#
# Applying them would silently undo a failover. To change their *defaults* on an
# existing cluster, patch them explicitly or redeploy from scratch.
#
# The StatefulSet is applied with server-side apply and WITHOUT spec.replicas, so
# deploy.sh never writes a replica count: a concurrent HPA scale cannot be
# overwritten by a stale value read a moment earlier.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

OVERLAY="manifests/overlays/lab"
for arg in "$@"; do
  case "$arg" in
    -*) echo "ERROR: unknown option $arg" >&2; exit 2 ;;
    *)  OVERLAY="$arg" ;;
  esac
done

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
oc kustomize "$OVERLAY" > "$TMP"

# An absent role ConfigMap means a fresh install. Any API error is fatal.
ROLE_OBJECT="$(oc -n "$NS" get configmap postgresql-role -o name --ignore-not-found)"
if [ -n "$ROLE_OBJECT" ]; then
  CUR_PRIMARY="$(oc -n "$NS" get cm postgresql-role -o jsonpath='{.data.PRIMARY_POD}')"
  CUR_RW="$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}')"
  CUR_RO="$(oc -n "$NS" get svc postgresql-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}')"
  CUR_REPLICAS="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}')"
  [ -n "$CUR_PRIMARY" ] && [ -n "$CUR_RW" ] && [ -n "$CUR_RO" ] && [ -n "$CUR_REPLICAS" ] || {
    echo "ERROR: incomplete live role, Service, or replica state; deploy aborted." >&2
    exit 1
  }
  if grep -q 'kind: HorizontalPodAutoscaler' "$TMP"; then
    case "$CUR_PRIMARY" in
      postgresql-0|postgresql-1) ;;
      *) echo "ERROR: the HPA could remove primary $CUR_PRIMARY on scale-down; fail back to ordinal 0 or 1 first." >&2
         exit 1 ;;
    esac
  fi
  python3 -c 'import yaml' 2>/dev/null || {
    echo "ERROR: reapplying an existing deployment requires python3 and PyYAML." >&2
    exit 1
  }
  # Drop the operational objects (role ConfigMap and routing Services) and the
  # replica count. Keeping spec.replicas out of the applied object means the HPA
  # (or whoever owns replicas) keeps owning it; server-side apply leaves absent
  # fields alone instead of resetting them, so no stale count is ever written.
  python3 - "$TMP" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path) as fh:
    docs = [doc for doc in yaml.safe_load_all(fh) if doc]
static = []
for doc in docs:
    key = (doc.get("kind"), doc.get("metadata", {}).get("name"))
    if key in {
        ("ConfigMap", "postgresql-role"),
        ("Service", "postgresql-rw"),
        ("Service", "postgresql-ro"),
    }:
        continue
    if key == ("StatefulSet", "postgresql"):
        doc.get("spec", {}).pop("replicas", None)
    static.append(doc)
with open(path, "w") as fh:
    yaml.safe_dump_all(static, fh, sort_keys=False, width=10**9)
PY
  echo "==> Applying $OVERLAY (preserving primary=$CUR_PRIMARY and replicas=$CUR_REPLICAS)"
  oc apply --server-side --force-conflicts -f "$TMP"
else
  echo "==> Applying $OVERLAY (fresh deployment)"
  oc apply -f "$TMP"
fi

echo "==> Credentials"
NAMESPACE="$NS" "$ROOT_DIR/scripts/generate-secret.sh"

echo "==> Waiting for the PostgreSQL pods to be Ready"
if ! wait_db_ready; then
  echo "ERROR: the pods did not become Ready in time" >&2
  oc -n "$NS" get pods,pvc >&2
  exit 1
fi
oc -n "$NS" get pods,pvc,svc
echo "Done. Verify replication with: ./scripts/verify-replication.sh"
