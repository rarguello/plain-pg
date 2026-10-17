#!/usr/bin/env bash
# t37 -- Growing a deployment that already exists. Kubernetes forbids editing the
#        StatefulSet's volumeClaimTemplates in place, so the PVCs are patched and
#        the template is updated by recreating the StatefulSet.
#
#        Destructive and irreversible: a PVC cannot shrink, so the lab's pgdata
#        PVCs stay bigger, and postgresql-backups is recreated to change its size.
#        It is run by hand (./tests/run-all.sh t37), not by the suite: every test
#        there leaves the lab consistent, and this one cannot.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t37 growing an existing deployment"

PRIMARY="$(primary_pod)"
MARK="grow-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_grow(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
pod_psql "$PRIMARY" -q -c "INSERT INTO t_grow(v) VALUES ('$MARK')" >/dev/null 2>&1
UID0="$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.metadata.uid}' 2>/dev/null)"
RESTARTS0="$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"

size() { oc -n "$NS" get pvc "$1" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null; }
capacity() { oc -n "$NS" get pvc "$1" -o jsonpath='{.status.capacity.storage}' 2>/dev/null; }
phase() { oc -n "$NS" get pvc "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
grow() {
  oc -n "$NS" patch pvc "$1" --type merge \
    -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}' >/dev/null 2>&1
}
has_row() { [ "$(pod_psql "$1" -tAc "SELECT count(*) FROM t_grow WHERE v='$MARK'" 2>/dev/null)" = "1" ]; }
streaming() { [ "$(streaming_count "$(primary_pod)")" = "1" ]; }

echo "  (patching the pgdata PVCs up to 3Gi)"
# The claim is what is being grown, so replication has to be up before, or the
# check after proves nothing.
wait_for 180 "replication is up before the growth" streaming
for p in pgdata-postgresql-0 pgdata-postgresql-1; do
  grow "$p" || c_fail "patching $p failed"
done
check_eq "pgdata-postgresql-0 asks for 3Gi" "3Gi" "$(size pgdata-postgresql-0)"
check_eq "pgdata-postgresql-1 asks for 3Gi" "3Gi" "$(size pgdata-postgresql-1)"

# The filesystem grows online, without restarting PostgreSQL.
grown() { [ "$(capacity pgdata-postgresql-0)" = "3Gi" ]; }
wait_for 180 "the filesystem of pgdata-postgresql-0 grew" grown
check_eq "the pod was not recreated" "$UID0" \
  "$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.metadata.uid}' 2>/dev/null)"
check_eq "and the container did not restart" "$RESTARTS0" \
  "$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
check "the data survived the growth" has_row "$PRIMARY"
check "replication was not affected" streaming

# No pod uses postgresql-backups, so it has no volume yet, and a claim without a
# volume cannot be changed at all, not even upwards (docs/operations.md).
if [ "$(phase postgresql-backups)" = "Pending" ]; then
  if grow postgresql-backups; then
    c_fail "a claim without a volume accepted a change"
  else
    c_ok "a claim without a volume refuses the change"
  fi
else
  grow postgresql-backups
  check_eq "a bound backups claim grows" "3Gi" "$(size postgresql-backups)"
fi

echo "  (recreating the StatefulSet so the template matches)"
oc -n "$NS" delete statefulset postgresql --wait=true >/dev/null 2>&1
# A claim that was never bound cannot be resized in place, so changing its size
# means recreating it. Nothing is lost: a claim without a volume holds no data.
oc -n "$NS" delete pvc postgresql-backups --ignore-not-found >/dev/null 2>&1
oc apply -k "$ROOT_DIR/manifests/overlays/ha-small" >/dev/null 2>&1 \
  || c_fail "applying overlays/ha-small failed"
wait_for 300 "the two pods are Ready again" wait_db_ready 2
check_eq "the template now asks for the smaller size" "1Gi" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}' 2>/dev/null)"
check_eq "and the PVC kept its own size" "3Gi" "$(size pgdata-postgresql-0)"
check_eq "the data is still there after the restart" "1" \
  "$(pod_psql "$(primary_pod)" -tAc "SELECT count(*) FROM t_grow WHERE v='$MARK'" 2>/dev/null || echo 0)"
check_eq "the filesystem is still the bigger one" "3Gi" "$(capacity pgdata-postgresql-0)"
wait_for 120 "replication is back" streaming

echo "  (back to the default profile)"
# A smaller template is the same immutability as a bigger one: the StatefulSet
# has to go for volumeClaimTemplates to change at all.
oc -n "$NS" delete statefulset postgresql --wait=true >/dev/null 2>&1
oc -n "$NS" delete pvc postgresql-backups --ignore-not-found >/dev/null 2>&1
oc apply -k "$ROOT_DIR/manifests/overlays/ha" >/dev/null 2>&1 \
  || c_fail "re-applying overlays/ha failed"
wait_for 300 "the two pods are Ready again" wait_db_ready 2
check_eq "the default template is back" "2Gi" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}' 2>/dev/null)"

t_summary
