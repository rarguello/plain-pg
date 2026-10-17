#!/usr/bin/env bash
# t37 -- Growing a deployment that already exists. Kubernetes forbids editing the
#        StatefulSet's volumeClaimTemplates in place, so the PVCs are patched and
#        the template is updated by recreating the StatefulSet.
#        Irreversible: a PVC cannot shrink, so the lab's PVCs stay bigger.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t37 growing an existing deployment"

PRIMARY="$(primary_pod)"
MARK="grow-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_grow(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
pod_psql "$PRIMARY" -q -c "INSERT INTO t_grow(v) VALUES ('$MARK')" >/dev/null 2>&1

size() { oc -n "$NS" get pvc "$1" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null; }
capacity() { oc -n "$NS" get pvc "$1" -o jsonpath='{.status.capacity.storage}' 2>/dev/null; }
has_row() { [ "$(pod_psql "$1" -tAc "SELECT count(*) FROM t_grow WHERE v='$MARK'" 2>/dev/null)" = "1" ]; }
streaming() { [ "$(streaming_count "$(primary_pod)")" = "1" ]; }

echo "  (patching the PVCs up to 3Gi)"
for p in pgdata-postgresql-0 pgdata-postgresql-1 postgresql-backups; do
  oc -n "$NS" patch pvc "$p" --type merge \
    -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}' >/dev/null 2>&1 \
    || c_fail "patching $p failed"
done
check_eq "pgdata-postgresql-0 asks for 3Gi" "3Gi" "$(size pgdata-postgresql-0)"
check_eq "pgdata-postgresql-1 asks for 3Gi" "3Gi" "$(size pgdata-postgresql-1)"
check_eq "the backups PVC asks for 3Gi" "3Gi" "$(size postgresql-backups)"

# The filesystem grows online, without restarting PostgreSQL.
grown() { [ "$(capacity pgdata-postgresql-0)" = "3Gi" ]; }
wait_for 180 "the filesystem of pgdata-postgresql-0 grew" grown
check_eq "and PostgreSQL never stopped" "f" "$(pod_in_recovery "$PRIMARY")"
check "the data survived the growth" has_row "$PRIMARY"
check "replication was not affected" streaming

echo "  (recreating the StatefulSet so the template matches)"
oc -n "$NS" delete statefulset postgresql --wait=true >/dev/null 2>&1
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
oc apply -k "$ROOT_DIR/manifests/overlays/ha" >/dev/null 2>&1 \
  || c_fail "re-applying overlays/ha failed"
check_eq "the default template is back" "2Gi" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}' 2>/dev/null)"

t_summary
