#!/usr/bin/env bash
# t28 -- External access: a NodePort on postgresql-rw reaches the primary, and
#        the NetworkPolicy keeps blocking clients from outside the namespace.
#        Destructive: it changes the Service type (restored at the end).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t28 external access (NodePort)"

NODE_IP="$(oc get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
NODE_PORT=30432
check "the node has an address" bash -c "[ -n '$NODE_IP' ]"

echo "  (deploying the external-access overlay)"
env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" "$ROOT_DIR/manifests/overlays/ha-external" >/dev/null

check_eq "postgresql-rw is a NodePort" "NodePort" \
  "$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.type}' 2>/dev/null)"
check_eq "it uses nodePort $NODE_PORT" "$NODE_PORT" \
  "$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)"
check_eq "it keeps selecting the primary" "$(primary_pod)" \
  "$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"
check_eq "externalTrafficPolicy is Local" "Local" \
  "$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.externalTrafficPolicy}' 2>/dev/null)"

# The NodePort path must reach the database. The client here is a pod inside the
# namespace (which the NetworkPolicy allows); an external client also needs an
# ipBlock allowlist -- see docs/operations.md.
nodeport_psql() {
  oc -n "$NS" exec "$(primary_pod)" -- env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h "$NODE_IP" -p "$NODE_PORT" -U postgres -d postgres -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "the NodePort reaches the primary" nodeport_psql

# ... and the default policy still refuses clients from outside the namespace.
check "the NetworkPolicy has no external ipBlock allow" bash -c \
  "! oc -n $NS get networkpolicy postgresql-ingress -o jsonpath='{.spec.ingress[*].from[*].ipBlock}' 2>/dev/null | grep -q ."

echo "  (restoring the ClusterIP Service)"
env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" "$ROOT_DIR/manifests/overlays/ha" >/dev/null
check_eq "postgresql-rw is a ClusterIP again" "ClusterIP" \
  "$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.type}' 2>/dev/null)"

t_summary
