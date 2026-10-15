#!/usr/bin/env bash
# t29 -- Failover guard: a standby that has been declared the new primary does NOT
#        promote while FAILOVER_GUARD is set. That is the window between declaring
#        the new role and confirming the old primary is fenced, where a
#        spontaneous restart could otherwise create a second primary.
#        Destructive: it changes the role ConfigMap and restarts a pod (restored
#        at the end, without ever running two primaries).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t29 failover guard"

PRIMARY="$(primary_pod)"
CANDIDATE="$(replica_pods | head -1)"

echo "  (declaring $CANDIDATE as primary and setting the guard, as a failover would)"
oc -n "$NS" patch cm postgresql-role --type merge \
  -p "{\"data\":{\"PRIMARY_POD\":\"$CANDIDATE\",\"FAILOVER_GUARD\":\"$CANDIDATE\"}}" >/dev/null

# The ConfigMap is mounted as a volume; wait until a pod can see the guard.
guard_visible() {
  [ "$(oc -n "$NS" exec "$CANDIDATE" -- cat /etc/plain-pg/role/FAILOVER_GUARD 2>/dev/null | tr -d '[:space:]')" = "$CANDIDATE" ]
}
wait_for 180 "the guard is visible in the mounted ConfigMap" guard_visible

echo "  (restarting $CANDIDATE: it must wait, not promote)"
oc -n "$NS" delete pod "$CANDIDATE" >/dev/null 2>&1
wait_for 180 "the entrypoint blocks on the guard" bash -c \
  "oc -n $NS logs $CANDIDATE 2>/dev/null | grep -q 'failover in progress'"
check "the candidate is NOT Ready while it waits" bash -c \
  "[ \"\$(oc -n $NS get pod $CANDIDATE -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)\" != true ]"
check_eq "the old primary is still the only primary" "f" "$(pod_in_recovery "$PRIMARY")"

echo "  (restoring: $PRIMARY stays primary, $CANDIDATE comes back as a standby)"
oc -n "$NS" patch cm postgresql-role --type merge \
  -p "{\"data\":{\"PRIMARY_POD\":\"$PRIMARY\",\"FAILOVER_GUARD\":\"\"}}" >/dev/null
oc -n "$NS" delete pod "$CANDIDATE" >/dev/null 2>&1
wait_for 300 "$CANDIDATE is a standby again" bash -c \
  "[ \"\$(oc -n $NS exec $CANDIDATE -- psql -U postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null)\" = t ]"
check_eq "$PRIMARY is still the primary" "f" "$(pod_in_recovery "$PRIMARY")"
check_eq "the guard is cleared" "" \
  "$(oc -n "$NS" get cm postgresql-role -o jsonpath='{.data.FAILOVER_GUARD}' 2>/dev/null)"

t_summary
