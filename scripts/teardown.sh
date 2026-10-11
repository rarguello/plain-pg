#!/usr/bin/env bash
#
# teardown.sh -- destroys the lab.
#
# Usage:
#   ./scripts/teardown.sh          # deletes the resources, PVCs and Secret
#                                  # (does NOT delete the namespace)
#   ./scripts/teardown.sh --all    # deletes the whole namespace
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

if [ "${1:-}" = "--all" ]; then
  echo "==> Deleting namespace $NS (removes EVERYTHING, including the PVCs)"
  oc delete namespace "$NS" --ignore-not-found --wait=true
  echo "==> Done"
  exit 0
fi

if ! oc get namespace "$NS" >/dev/null 2>&1; then
  echo "==> Namespace $NS does not exist; nothing to delete"
  exit 0
fi

# It is deleted by label, not with `oc delete -k`, to NOT include the Namespace
# object (which is one more resource in the overlay). The namespace is only
# deleted with --all.
echo "==> Deleting resources in namespace $NS"
oc -n "$NS" delete \
  statefulset,service,configmap,cronjob,job,networkpolicy,serviceaccount,role,rolebinding \
  -l app.kubernetes.io/part-of=plain-pg --ignore-not-found

echo "==> Deleting PVCs (the StatefulSet does not delete them by itself)"
oc -n "$NS" delete pvc -l app.kubernetes.io/part-of=plain-pg --ignore-not-found

echo "==> Deleting the Secret"
oc -n "$NS" delete secret postgresql-credentials --ignore-not-found

echo "==> Done (namespace $NS kept)"
