#!/usr/bin/env bash
# t07 -- Complete MANUAL failover, round trip (failback).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t07 manual failover (round trip)"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_failover(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="fo-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_failover(v) VALUES ('$MARK')" >/dev/null 2>&1
has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_failover WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
streaming() { [ "$(streaming_count "$1")" = "1" ]; }
wait_for 30 "row '$MARK' replicates before the failover" has_row "$REPLICA" "$MARK"

# --- FAILOVER ---
echo "  (running scripts/failover-manual.sh $REPLICA)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$REPLICA" || c_fail "the failover script failed"

check_eq "the ConfigMap declares $REPLICA as primary" "$REPLICA" "$(primary_pod)"
check_eq "$REPLICA is now primary" "f" "$(pod_in_recovery "$REPLICA")"
wait_for 300 "$PRIMARY re-seeds as a replica" bash -c "[ \"\$(oc -n $NS get pod $PRIMARY -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$PRIMARY is now standby" "t" "$(pod_in_recovery "$PRIMARY")"
check "previous data survives on the new primary" has_row "$REPLICA" "$MARK"
wait_for 180 "replication runs in the new direction" streaming "$REPLICA"

IP_NEW="$(oc -n "$NS" get pod "$REPLICA" -o jsonpath='{.status.podIP}')"
check_eq "postgresql-rw was repointed to the new primary" "$IP_NEW" \
  "$(oc -n "$NS" get endpoints postgresql-rw -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
IP_OLD="$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.status.podIP}')"
check_eq "postgresql-ro was repointed to the new replica" "$IP_OLD" \
  "$(oc -n "$NS" get endpoints postgresql-ro -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"

# Re-applying the manifests must NOT revert the failover
echo "  (re-applying manifests with $REPLICA as primary)"
NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" >/dev/null 2>&1 || c_fail "deploy.sh failed after the failover"
check_eq "deploy.sh preserves PRIMARY_POD=$REPLICA" "$REPLICA" "$(primary_pod)"
check_eq "deploy.sh preserves the postgresql-rw selector" "$REPLICA" \
  "$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"
check_eq "deploy.sh preserves the postgresql-ro selector" "$PRIMARY" \
  "$(oc -n "$NS" get svc postgresql-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"

# --- FAILBACK ---
echo "  (failback: promoting $PRIMARY back)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$PRIMARY" || c_fail "the failback failed"
check_eq "the ConfigMap declares $PRIMARY again" "$PRIMARY" "$(primary_pod)"
check_eq "$PRIMARY is primary again" "f" "$(pod_in_recovery "$PRIMARY")"
wait_for 300 "$REPLICA becomes a replica again" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$REPLICA is standby again" "t" "$(pod_in_recovery "$REPLICA")"
check "data survives the failback" has_row "$PRIMARY" "$MARK"
wait_for 180 "replication is re-established" streaming "$PRIMARY"

t_summary
