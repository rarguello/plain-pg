#!/usr/bin/env bash
# t34 -- Storage size: the size of the PVCs is chosen when the deployment is
#        created (overlays/ha-small asks for 1Gi instead of the default 2Gi).
#        Destructive: it tears the lab down and deploys it twice.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t34 storage size"

size_of() { oc -n "$NS" get pvc "$1" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null; }

echo "  (a fresh deployment with a smaller size)"
"$ROOT_DIR/scripts/teardown.sh" >/dev/null 2>&1
if "$ROOT_DIR/scripts/deploy.sh" "$ROOT_DIR/manifests/overlays/ha-small" >/dev/null 2>&1; then
  c_ok "deploying overlays/ha-small completes"
else
  c_fail "deploying overlays/ha-small failed"
fi
wait_for 300 "the two pods are Ready" wait_db_ready 2

check_eq "the StatefulSet asks for the smaller size" "1Gi" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}' 2>/dev/null)"
check_eq "pgdata-postgresql-0 was created with it" "1Gi" "$(size_of pgdata-postgresql-0)"
check_eq "pgdata-postgresql-1 was created with it" "1Gi" "$(size_of pgdata-postgresql-1)"
check_eq "the backups PVC was created with it" "1Gi" "$(size_of postgresql-backups)"
check_eq "the primary is up on it" "f" "$(pod_in_recovery "$(primary_pod)")"
check_eq "replication works" "1" "$(streaming_count "$(primary_pod)")"

MARK="size-$(date +%s)-$RANDOM"
pod_psql "$(primary_pod)" -q -c "CREATE TABLE IF NOT EXISTS t_size(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
pod_psql "$(primary_pod)" -q -c "INSERT INTO t_size(v) VALUES ('$MARK')" >/dev/null 2>&1
check_eq "a write works on the smaller volume" "1" \
  "$(pod_psql "$(primary_pod)" -tAc "SELECT count(*) FROM t_size WHERE v='$MARK'" 2>/dev/null || echo 0)"

echo "  (back to the default profile)"
"$ROOT_DIR/scripts/teardown.sh" >/dev/null 2>&1
if "$ROOT_DIR/scripts/deploy.sh" >/dev/null 2>&1; then
  c_ok "redeploying the default profile completes"
else
  c_fail "redeploying the default profile failed"
fi
wait_for 300 "the two pods are Ready again" wait_db_ready 2
check_eq "the default size is back" "2Gi" "$(size_of pgdata-postgresql-0)"
check_eq "the backups PVC is back to the default" "2Gi" "$(size_of postgresql-backups)"
check_eq "replication is back" "1" "$(streaming_count "$(primary_pod)")"

t_summary
