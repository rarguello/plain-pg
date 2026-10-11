#!/usr/bin/env bash
# t09 -- Idempotency: applying twice changes nothing.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

echo "### t09 idempotency"

OVERLAY="$ROOT_DIR/manifests/overlays/lab"
if oc -n "$NS" get hpa postgresql-read >/dev/null 2>&1; then
  c_skip "an HPA owns replicas; run this test without the read-scaling component"
  t_summary
  exit $?
fi

# resourceVersion of the key objects: it is the real idempotency signal.
# (The word "configured/unchanged" from `oc apply` is not used: for a
#  StatefulSet with volumeClaimTemplates, kubectl/oc always prints
#  "configured" even when nothing changes. See docs/operations.md.)
key_rvs() {
  local r rv
  for r in sts/postgresql svc/postgresql-hl svc/postgresql-rw svc/postgresql-ro \
           cm/postgresql-scripts cm/postgresql-role cronjob/postgresql-failover \
           networkpolicy/postgresql-ingress; do
    rv="$(oc -n "$NS" get "$r" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"
    [ -n "$rv" ] || echo "MISSING:$r"      # an empty lookup must not pass silently
    echo "$rv"
  done
}

# Sync the state with the repo before measuring.
env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" "$OVERLAY" >/dev/null
BEFORE="$(key_rvs)"
env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" "$OVERLAY" >/dev/null
AFTER="$(key_rvs)"
check_eq "a second apply modifies no object (stable resourceVersion)" "$BEFORE" "$AFTER"

# The kustomize render is deterministic
A="$(oc kustomize "$OVERLAY" 2>/dev/null | sha256sum)"
B="$(oc kustomize "$OVERLAY" 2>/dev/null | sha256sum)"
check_eq "kustomize always produces the same render" "$A" "$B"

# deploy.sh is idempotent (it does not fail when re-run)
check "deploy.sh re-runs without error" \
  env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh"

# The image is still pinned by digest (pinning is not broken)
IMG="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
check_contains "the image is still pinned by digest" "@sha256:" "$IMG"

t_summary
