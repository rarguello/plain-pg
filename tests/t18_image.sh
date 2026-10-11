#!/usr/bin/env bash
# t18 -- Image: the digest pinned in the overlay matches the registry one and
#        the one the pods use.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

echo "### t18 image and digest"

PIN="$(grep -oE 'sha256:[0-9a-f]{64}' "$ROOT_DIR/manifests/overlays/lab/kustomization.yaml" | head -1)"
check "the overlay pins a digest" bash -c "[ -n '$PIN' ]"

RUNNING="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
check_contains "the StatefulSet uses the pinned digest" "$PIN" "$RUNNING"

# Note: .status.image is the pinned reference (manifest-list digest, multi-arch);
# .status.imageID is the platform image digest (amd64), which is different. That
# is why the reference is compared, not the imageID.
POD_IMAGE="$(oc -n "$NS" get pod "$(primary_pod)" -o jsonpath='{.status.containerStatuses[0].image}')"
check_eq "the pod runs exactly that reference" "$RUNNING" "$POD_IMAGE"
POD_IMAGEID="$(oc -n "$NS" get pod "$(primary_pod)" -o jsonpath='{.status.containerStatuses[0].imageID}')"
check_match "the imageID resolves to the same repository" \
  "^registry\.redhat\.io/rhel10/postgresql-18@sha256:[0-9a-f]{64}$" "$POD_IMAGEID"

AUTHFILE="${AUTHFILE:-$HOME/.pull-secret.json}"
if command -v skopeo >/dev/null 2>&1 && [ -f "$AUTHFILE" ]; then
  LIVE="$(skopeo inspect --authfile "$AUTHFILE" docker://registry.redhat.io/rhel10/postgresql-18:latest 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' | head -1)"
  check_eq "the pinned digest is the current registry one" "$LIVE" "$PIN"
else
  c_skip "skopeo or the authfile are not available; not compared with the registry"
fi

# The image is PostgreSQL 18 on UBI10
check_match "the image declares PLATFORM el10" "el10" \
  "$(oc -n "$NS" exec "$(primary_pod)" -- printenv PLATFORM 2>/dev/null)"
check_match "postgres is 18.x" "^postgres \(PostgreSQL\) 18\." \
  "$(oc -n "$NS" exec "$(primary_pod)" -- postgres --version 2>/dev/null)"

t_summary
