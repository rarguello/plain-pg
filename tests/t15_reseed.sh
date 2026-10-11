#!/usr/bin/env bash
# t15 -- Replica recovery: scripts/reseed-replica.sh re-seeds it from scratch and
#        it stays replicating.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t15 replica re-seed"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
streaming() { [ "$(streaming_count "$PRIMARY")" = "1" ]; }

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_reseed(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="rs-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_reseed(v) VALUES ('$MARK')" >/dev/null 2>&1
has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_reseed WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
wait_for 30 "data reaches the replica before re-seeding" has_row "$REPLICA" "$MARK"

PVC_UID_BEFORE="$(oc -n "$NS" get pvc "pgdata-$REPLICA" -o jsonpath='{.metadata.uid}')"

echo "  (re-seeding $REPLICA)"
if ! "$ROOT_DIR/scripts/reseed-replica.sh" "$REPLICA" >/dev/null 2>&1; then
  c_fail "reseed-replica.sh failed"
fi

wait_for 300 "$REPLICA becomes Ready again" pod_ready "$REPLICA"
check_ne "the replica PVC was recreated (different UID)" "$PVC_UID_BEFORE" \
  "$(oc -n "$NS" get pvc "pgdata-$REPLICA" -o jsonpath='{.metadata.uid}')"
check_eq "$REPLICA is standby after the re-seed" "t" "$(pod_in_recovery "$REPLICA")"
check "data is still on the re-seeded replica" has_row "$REPLICA" "$MARK"
check "the re-seed was recorded in the logs" \
  bash -c "oc -n $NS logs $REPLICA 2>/dev/null | grep -q 'pg_basebackup'"
wait_for 120 "replication is re-established" streaming

t_summary
