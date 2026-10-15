#!/usr/bin/env bash
# t06 -- Persistence and self-recovery: restarting pods does not lose data or
#        re-seed the replica unnecessarily.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t06 persistence and restarts"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_persist(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="persist-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_persist(v) VALUES ('$MARK')" >/dev/null 2>&1

has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_persist WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
streaming() { [ "$(streaming_count "$1")" = "1" ]; }

wait_for 30 "row '$MARK' replicates" has_row "$REPLICA" "$MARK"

# --- Restart of the REPLICA ---
PVC_UID_BEFORE="$(oc -n "$NS" get pvc "pgdata-$REPLICA" -o jsonpath='{.metadata.uid}')"
echo "  (restarting the replica $REPLICA)"
oc -n "$NS" delete pod "$REPLICA" >/dev/null 2>&1
wait_for 180 "the replica becomes Ready again" pod_ready "$REPLICA"
check_eq "the replica keeps its PVC (same UID)" "$PVC_UID_BEFORE" \
  "$(oc -n "$NS" get pvc "pgdata-$REPLICA" -o jsonpath='{.metadata.uid}')"
check "the replica did NOT re-seed (no 'wiping PGDATA' in logs)" \
  bash -c "! oc -n $NS logs $REPLICA 2>/dev/null | grep -q 'wiping PGDATA'"
check_eq "the replica is still standby after restarting" "t" "$(pod_in_recovery "$REPLICA")"
check "row '$MARK' is still on the replica" has_row "$REPLICA" "$MARK"
wait_for 90 "replication resumes after restarting the replica" streaming "$PRIMARY"

# --- Restart of the PRIMARY ---
echo "  (restarting the primary $PRIMARY)"
oc -n "$NS" delete pod "$PRIMARY" >/dev/null 2>&1
wait_for 240 "the primary becomes Ready again" pod_ready "$PRIMARY"
check_eq "the primary is still primary" "f" "$(pod_in_recovery "$PRIMARY")"
check "row '$MARK' is still on the primary" has_row "$PRIMARY" "$MARK"
# A slow runner can take a while to re-establish the stream (the lab needs
# seconds); the timeout only has to catch a real break, and the diagnostic
# below is printed when it fires.
wait_for 240 "replication resumes after restarting the primary" streaming "$PRIMARY" \
  || diag_replication "$PRIMARY" "$REPLICA"

t_summary
