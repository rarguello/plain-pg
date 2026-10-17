#!/usr/bin/env bash
#
# deploy.sh -- deploys plain-pg without clobbering live failover state.
#
# Usage:
#   ./scripts/deploy.sh                                 # lab (automatic failover)
#   ./scripts/deploy.sh manifests/overlays/ha-manual   # manual failover only
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

OVERLAY="manifests/overlays/ha"
for arg in "$@"; do
  case "$arg" in
    -*) echo "ERROR: unknown option $arg" >&2; exit 2 ;;
    *)  OVERLAY="$arg" ;;
  esac
done

TMP="$(mktemp)"
STS_PATCH="$(mktemp)"
RW_PATCH="$(mktemp)"
RO_PATCH="$(mktemp)"
trap 'rm -f "$TMP" "$STS_PATCH" "$RW_PATCH" "$RO_PATCH"' EXIT
oc kustomize "$OVERLAY" > "$TMP"

# An absent role ConfigMap means a fresh install. Any API error is fatal.
ROLE_OBJECT="$(oc -n "$NS" get configmap postgresql-role -o name --ignore-not-found)"
if [ -n "$ROLE_OBJECT" ]; then
  CUR_PRIMARY="$(oc -n "$NS" get cm postgresql-role -o jsonpath='{.data.PRIMARY_POD}' || true)"
  CUR_RW="$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' || true)"
  CUR_RO="$(oc -n "$NS" get svc postgresql-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' || true)"
  STS_OBJECT="$(oc -n "$NS" get sts postgresql -o name --ignore-not-found || true)"
  [ -n "$CUR_PRIMARY" ] && [ -n "$CUR_RW" ] && [ -n "$CUR_RO" ] || {
    echo "ERROR: incomplete live role or Service state; deploy aborted." >&2
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
  # The role ConfigMap is dropped: PRIMARY_POD and AUTO_FAILOVER belong to the
  # failover scripts. The StatefulSet and the two routing Services are applied
  # with MERGE PATCHES that omit the operational fields -- spec.replicas for the
  # StatefulSet, spec.selector for the Services -- so a live failover and a live
  # replica count are preserved while everything else (for example the Service
  # `type` of overlays/ha-external) still applies. Server-side apply would prune
  # a field as soon as this script had owned it (and the API would re-default
  # spec.replicas to 1).
  python3 - "$TMP" "$STS_PATCH" "$RW_PATCH" "$RO_PATCH" \
    "$([ -n "$STS_OBJECT" ] && echo 1 || echo 0)" <<'PY'
import json
import sys
import yaml

path, sts_patch, rw_patch, ro_patch, existing = sys.argv[1:6]
existing = existing == "1"
with open(path) as fh:
    docs = [doc for doc in yaml.safe_load_all(fh) if doc]
static = []
for doc in docs:
    key = (doc.get("kind"), doc.get("metadata", {}).get("name"))
    if key == ("ConfigMap", "postgresql-role"):
        continue
    if key == ("StatefulSet", "postgresql") and existing:
        doc.get("spec", {}).pop("replicas", None)
        json.dump(doc, open(sts_patch, "w"))
        continue
    if key in {("Service", "postgresql-rw"), ("Service", "postgresql-ro")}:
        # Preserve the live selector (a failover owns it), but make the rest of
        # the spec authoritative: `type` defaults to ClusterIP when the overlay
        # does not set it, and a merge patch replaces the ports list wholesale,
        # which is what removes a leftover nodePort.
        spec = doc.setdefault("spec", {})
        spec.pop("selector", None)
        spec.setdefault("type", "ClusterIP")
        if spec["type"] == "ClusterIP":
            spec["externalTrafficPolicy"] = None   # null removes it
        json.dump(doc, open(rw_patch if key[1].endswith("-rw") else ro_patch, "w"))
        continue
    static.append(doc)
with open(path, "w") as fh:
    yaml.safe_dump_all(static, fh, sort_keys=False, width=10**9)
PY
  echo "==> Applying $OVERLAY (preserving primary=$CUR_PRIMARY)"
  oc apply --server-side --force-conflicts -f "$TMP"
  if [ -s "$STS_PATCH" ]; then
    oc -n "$NS" patch sts postgresql --type=merge --patch-file "$STS_PATCH" >/dev/null
  fi
  [ -s "$RW_PATCH" ] && oc -n "$NS" patch svc postgresql-rw --type=merge --patch-file "$RW_PATCH" >/dev/null
  [ -s "$RO_PATCH" ] && oc -n "$NS" patch svc postgresql-ro --type=merge --patch-file "$RO_PATCH" >/dev/null
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
