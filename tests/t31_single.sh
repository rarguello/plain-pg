#!/usr/bin/env bash
# t31 -- Single instance, and the step from there to HA: overlays/single
#        runs one pod with the same hardening as the HA profile, and scaling the
#        StatefulSet to 2 replicas brings up a hot standby on its own.
#        Destructive: it changes the topology (restored at the end).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t31 single instance (no replica)"

echo "  (applying overlays/single)"
oc apply -k "$ROOT_DIR/manifests/overlays/single" >/dev/null 2>&1 \
  || c_fail "applying overlays/single failed"
# `oc apply` does not prune: coming from the HA profile, remove what the single
# profile does not define (see docs/operations.md).
oc -n "$NS" delete svc postgresql-ro --ignore-not-found >/dev/null 2>&1
oc -n "$NS" delete cronjob postgresql-failover --ignore-not-found >/dev/null 2>&1

one_pod() { [ "$(db_pods | wc -l | tr -d ' ')" = "1" ]; }
wait_for 180 "only one database pod remains" one_pod
wait_for 300 "the single pod is Ready" wait_db_ready 1

check_eq "exactly one database pod" "1" "$(db_pods | wc -l | tr -d ' ')"
check_eq "it is the primary" "f" "$(pod_in_recovery "$(primary_pod)")"
check "there is no replica Service" bash -c "! oc -n $NS get svc postgresql-ro >/dev/null 2>&1"
check "there is no automatic-failover CronJob" \
  bash -c "! oc -n $NS get cronjob postgresql-failover >/dev/null 2>&1"
check "the backup CronJob is kept" oc -n "$NS" get cronjob postgresql-backup
check "the NetworkPolicy is kept" oc -n "$NS" get networkpolicy postgresql-ingress

MARK="single-$(date +%s)-$RANDOM"
pod_psql "$(primary_pod)" -q -c \
  "CREATE TABLE IF NOT EXISTS t_single(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
pod_psql "$(primary_pod)" -q -c "INSERT INTO t_single(v) VALUES ('$MARK')" >/dev/null 2>&1

through() {   # through <service>
  [ "$(oc -n "$NS" exec "$(primary_pod)" -- env PGPASSWORD="$APP_PASSWORD" \
       psql -h "$1" -U "$APP_USER" -d "$APP_DB" -tAc \
       "SELECT count(*) FROM t_single WHERE v='$MARK'" 2>/dev/null)" = "1" ]
}
check "a write through postgresql-rw is visible" through postgresql-rw
check "postgresql-r serves reads from the same instance" through postgresql-r

OUT="$("$ROOT_DIR/scripts/backup-now.sh" 2>&1 || true)"
check_contains "a backup still works" "[pg-backup] OK" "$OUT"

echo "  (the HA step: 2 replicas -> a hot standby appears on its own)"
oc -n "$NS" scale sts postgresql --replicas=2 >/dev/null 2>&1
wait_for 300 "the second pod is Ready" wait_db_ready 2
check_eq "the new pod is a hot standby" "t" "$(pod_in_recovery "$(replica_pods | head -1)")"
streaming() { [ "$(streaming_count "$(primary_pod)")" = "1" ]; }
wait_for 120 "replication is streaming" streaming
check "the replicated row is visible through postgresql-r" through postgresql-r

echo "  (restoring the full lab overlay)"
oc apply -k "$ROOT_DIR/manifests/overlays/ha" >/dev/null 2>&1 \
  || c_fail "applying overlays/ha failed"
wait_for 300 "two pods are Ready again" wait_db_ready 2
check_eq "replication is still streaming" "1" "$(streaming_count "$(primary_pod)")"
check "the replica Service is back" oc -n "$NS" get svc postgresql-ro

t_summary
