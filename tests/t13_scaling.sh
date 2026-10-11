#!/usr/bin/env bash
# t13 -- Scaling: adding a second replica seeds it and leaves it replicating.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t13 replica scaling"

# Manual scaling is meaningless while an HPA owns `replicas`: it would undo it.
if oc -n "$NS" get hpa postgresql-read >/dev/null 2>&1; then
  c_skip "an HPA (postgresql-read) owns the replica count; manual scaling is not testable"
  t_summary
  exit $?
fi

PRIMARY="$(primary_pod)"
streaming() { [ "$(streaming_count "$PRIMARY")" = "$1" ]; }

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_scale(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="sc-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_scale(v) VALUES ('$MARK')" >/dev/null 2>&1

echo "  (scaling to 3 pods)"
oc -n "$NS" scale statefulset postgresql --replicas=3 >/dev/null
wait_for 420 "postgresql-2 becomes Ready" pod_ready postgresql-2
check_eq "postgresql-2 is standby" "t" "$(pod_in_recovery postgresql-2)"
check_eq "the primary sees 2 replicas streaming" "2" "$(streaming_count "$PRIMARY")"
has_row() { pod_psql "$1" -tAc "SELECT 1 FROM t_scale WHERE v='$2' LIMIT 1" 2>/dev/null | grep -qx 1; }
check "postgresql-2 received the existing data" has_row postgresql-2 "$MARK"

# postgresql-r picks the new replica up with no Service change.
new_ip="$(oc -n "$NS" get pod postgresql-2 -o jsonpath='{.status.podIP}')"
check "postgresql-r includes the new replica automatically" \
  bash -c "oc -n $NS get endpoints postgresql-r -o jsonpath='{.subsets[*].addresses[*].ip}' | grep -qw '$new_ip'"

# The -rw Service still points only at the primary
check_eq "postgresql-rw is still on the primary" \
  "$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.status.podIP}')" \
  "$(oc -n "$NS" get endpoints postgresql-rw -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"

echo "  (scaling back to 2 pods)"
oc -n "$NS" scale statefulset postgresql --replicas=2 >/dev/null
wait_for 180 "postgresql-2 is deleted" bash -c "! oc -n $NS get pod postgresql-2 >/dev/null 2>&1"
check "the postgresql-2 PVC is left orphaned (expected behavior)" \
  oc -n "$NS" get pvc pgdata-postgresql-2
wait_for 120 "1 replica remains streaming" streaming 1

# Cleanup of the orphaned PVC
oc -n "$NS" delete pvc pgdata-postgresql-2 --ignore-not-found >/dev/null 2>&1 || true

t_summary
