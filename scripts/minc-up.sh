#!/usr/bin/env bash
#
# minc-up.sh -- prepare a fresh MINC (MicroShift-in-a-container) cluster so the
# test suite can run against it. CI/dev bootstrap only: it is NOT part of a real
# install.
#
# MicroShift ships no StorageClass and does not wire a pull secret, so the suite
# cannot run until both exist. This adds:
#   - a dynamic provisioner (Rancher local-path) and makes its StorageClass the
#     cluster default. MicroShift's own LVMS is the real thing, but it needs a
#     volume group that a container does not have, so the CI cluster uses the
#     same tiny hostPath provisioner that kind/k3s ship;
#   - the Red Hat pull secret on the namespace's default ServiceAccount.
#
# The tests read the expected StorageClass from `STORAGE_CLASS` (default
# `lvms-vg1`), so the nightly run sets `STORAGE_CLASS=local-path`.
#
# Idempotent. Requires `oc` (or `kubectl`) pointed at the MINC cluster.
#
# Env:
#   PULL_SECRET  path to a Red Hat pull secret (default: ~/.pull-secret.json)
#   NAMESPACE    target namespace (default: plain-pg)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-plain-pg}"
PULL_SECRET="${PULL_SECRET:-$HOME/.pull-secret.json}"
LOCAL_PATH_VERSION="v0.0.30"

# 1. Storage: the local-path provisioner, made the cluster default.
if ! oc get storageclass local-path >/dev/null 2>&1; then
  echo "==> Installing the local-path provisioner"
  oc apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
  # Its helper pod uses a hostPath volume, which needs an SCC that allows it.
  oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-hostmount
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: local-path-storage
roleRef:
  kind: ClusterRole
  name: system:openshift:scc:hostmount-anyuid
  apiGroup: rbac.authorization.k8s.io
EOF
fi
oc patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null

# 2. Pull secret for registry.redhat.io (the PostgreSQL image).
echo "==> Wiring the pull secret into namespace $NS"
oc apply -f "$ROOT_DIR/manifests/base/namespace.yaml"
if [ -f "$PULL_SECRET" ]; then
  oc -n "$NS" create secret generic redhat-pull \
    --from-file=.dockerconfigjson="$PULL_SECRET" \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc -n "$NS" patch serviceaccount default \
    -p '{"imagePullSecrets":[{"name":"redhat-pull"}]}' >/dev/null
else
  echo "WARNING: $PULL_SECRET not found; the PostgreSQL image will not pull" >&2
fi

echo "==> MINC cluster is ready for the suite (namespace $NS, storageclass local-path)"
