#!/usr/bin/env bash
# t11 -- Teardown and redeploy from scratch (tests the full lifecycle).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t11 teardown and redeploy"

echo "  (teardown)"
"$ROOT_DIR/scripts/teardown.sh" >/dev/null 2>&1

check "no DB pods remain" \
  bash -c "! oc -n $NS get pods -l app.kubernetes.io/component=database 2>/dev/null | grep -q postgresql-0"
check "no DB PVCs remain" \
  bash -c "! oc -n $NS get pvc -l app.kubernetes.io/instance=postgresql 2>/dev/null | grep -q pgdata-"
check "the Secret is gone" \
  bash -c "! oc -n $NS get secret postgresql-credentials >/dev/null 2>&1"
check "the normal teardown does NOT delete the namespace" oc get namespace "$NS"

echo "  (redeploy from scratch)"
if NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" >/dev/null 2>&1; then
  c_ok "deploy.sh completes the deployment"
else
  c_fail "deploy.sh failed on the redeploy"
fi

wait_for 300 "postgresql-0 Ready after the redeploy" pod_ready postgresql-0
wait_for 300 "postgresql-1 Ready after the redeploy" pod_ready postgresql-1
check_eq "postgresql-0 is primary after the redeploy" "f" "$(pod_in_recovery postgresql-0)"
check_eq "postgresql-1 is standby after the redeploy" "t" "$(pod_in_recovery postgresql-1)"
check_eq "replication active after the redeploy" "1" "$(streaming_count postgresql-0)"

# The new PVC must be Bound
check_eq "the postgresql-0 PVC is Bound" "Bound" \
  "$(oc -n "$NS" get pvc pgdata-postgresql-0 -o jsonpath='{.status.phase}' 2>/dev/null)"

t_summary
