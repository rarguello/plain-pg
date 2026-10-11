#!/usr/bin/env bash
# t20 -- After a failover, recreating BOTH pods at once leaves the roles
#        correct. It is the test for the change to podManagementPolicy: Parallel
#        (with OrderedReady this would be a deadlock).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t20 full restart after failover"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
streaming() { [ "$(streaming_count "$1")" = "1" ]; }

echo "  (failover to $REPLICA)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$REPLICA" >/dev/null 2>&1 || c_fail "the failover failed"
wait_for 300 "$REPLICA is primary" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"

echo "  (recreating BOTH pods at once)"
oc -n "$NS" delete pod "$PRIMARY" "$REPLICA" >/dev/null 2>&1

wait_for 420 "$REPLICA becomes Ready again (as primary)" pod_ready "$REPLICA"
wait_for 420 "$PRIMARY becomes Ready again (as replica)" pod_ready "$PRIMARY"
check_eq "$REPLICA is still primary" "f" "$(pod_in_recovery "$REPLICA")"
check_eq "$PRIMARY came back as standby" "t" "$(pod_in_recovery "$PRIMARY")"
wait_for 180 "replication is re-established after the full restart" streaming "$REPLICA"

echo "  (failback)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$PRIMARY" >/dev/null 2>&1 || c_fail "the failback failed"
check_eq "$PRIMARY is primary again" "f" "$(pod_in_recovery "$PRIMARY")"
wait_for 300 "$REPLICA is standby again" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$REPLICA is standby again" "t" "$(pod_in_recovery "$REPLICA")"

t_summary
