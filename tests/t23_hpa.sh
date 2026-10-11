#!/usr/bin/env bash
# t23 -- Read avalanche: with the read-scaling component, the HPA grows the
#        fleet under read load, the new replica joins postgresql-r by itself and
#        actually serves reads. Restores the starting state at the end.
#
# Slow (it waits for real HPA decisions). Only run it in the full suite.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t23 HPA: scale up under read load"

PRIMARY="$(primary_pod)"
IMG="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
JOB="t23-load-$$"
LOAD_SECONDS=240
CLIENTS=12
BENCH_DB=pgbench

# Record the starting state so the test can restore exactly that.
START_REPLICAS="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}')"
HAD_HPA=0
oc -n "$NS" get hpa postgresql-read >/dev/null 2>&1 && HAD_HPA=1
echo "  starting state: replicas=$START_REPLICAS hpa=$HAD_HPA"

# PVCs that already exist: the cleanup below must not delete them.
PVC_BEFORE="$(oc -n "$NS" get pvc -o name 2>/dev/null | sed 's|.*/||' | grep '^pgdata-postgresql-' | sort || true)"

# Restore the starting state even if the test is interrupted.
cleanup() {
  oc -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
  [ "$HAD_HPA" = "1" ] || oc -n "$NS" delete hpa postgresql-read --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$NS" scale statefulset postgresql --replicas="$START_REPLICAS" >/dev/null 2>&1 || true
}
trap cleanup EXIT
if [ "$HAD_HPA" = 1 ] || [ "$START_REPLICAS" != 2 ] || [ "$PRIMARY" != postgresql-0 ]; then
  c_skip "t23 requires two pods, primary postgresql-0, and no existing HPA"
  t_summary
  exit $?
fi

echo "  (deploying the read-scaling component)"
env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" "$ROOT_DIR/manifests/overlays/lab-autoscale" >/dev/null
check "the HPA exists" oc -n "$NS" get hpa postgresql-read
check_eq "minReplicas is 2" "2" \
  "$(oc -n "$NS" get hpa postgresql-read -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"

# The lab is a single node that is already busy: a 5-pod fleet over-subscribes it
# (the extra replicas stay Pending on the node's pod limit) and the churn makes
# this test flaky. Cap the HPA for the test; one extra replica is enough to prove
# that autoscaling adds a replica and that postgresql-r routes reads to it.
# The shipped maxReplicas lives in components/read-scaling/hpa.yaml.
oc -n "$NS" patch hpa postgresql-read --type merge -p '{"spec":{"maxReplicas":3}}' >/dev/null

hpa_has_metrics() {
  [ -n "$(oc -n "$NS" get hpa postgresql-read -o jsonpath='{.status.currentMetrics}' 2>/dev/null)" ]
}
wait_for 240 "the HPA reports live metrics" hpa_has_metrics

# Dedicated benchmark database, owned by the app user. Created on the primary
# (it replicates); initialized only if the pgbench tables are missing.
if [ "$(pod_psql_admin "$PRIMARY" -tAc "SELECT count(*) FROM pg_database WHERE datname='$BENCH_DB'")" = "0" ]; then
  oc -n "$NS" exec "$PRIMARY" -- env PGPASSWORD="$ADMIN_PASSWORD" psql \
    -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"$BENCH_DB\" OWNER \"$APP_USER\";" >/dev/null
fi
bench_tables_exist() {
  oc -n "$NS" exec "$PRIMARY" -- env PGPASSWORD="$ADMIN_PASSWORD" psql \
    -h 127.0.0.1 -U postgres -d "$BENCH_DB" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_name='pgbench_accounts'" 2>/dev/null | grep -qx 1
}
if ! bench_tables_exist; then
  oc -n "$NS" exec "$PRIMARY" -- env PGPASSWORD="$APP_PASSWORD" \
    pgbench -i -q -s 1 -h postgresql-rw -U "$APP_USER" -d "$BENCH_DB" >/dev/null \
    || c_fail "pgbench initialization failed"
fi

oc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  labels:
    app.kubernetes.io/name: pg-load
    app.kubernetes.io/instance: plain-pg
    app.kubernetes.io/part-of: plain-pg
    app.kubernetes.io/component: test
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $((LOAD_SECONDS + 120))
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pg-load
        app.kubernetes.io/instance: plain-pg
        app.kubernetes.io/part-of: plain-pg
        app.kubernetes.io/component: test
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: pgbench
          image: $IMG
          command: ["pgbench","-S","-c","$CLIENTS","-j","4","-T","$LOAD_SECONDS","-h","postgresql-r","-U","$APP_USER","-d","$BENCH_DB"]
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef: { name: postgresql-credentials, key: POSTGRESQL_PASSWORD }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF

scaled_up() { [ "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}')" -ge 3 ]; }
wait_for 600 "the HPA grows the fleet under read load" scaled_up

NEW="$(db_pods | tail -1)"
echo "    fleet grew to $(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}') pods (new: $NEW)"
wait_for 420 "$NEW becomes Ready" pod_ready "$NEW"
check_eq "$NEW is a standby" "t" "$(pod_in_recovery "$NEW")"

# The Endpoints object updates a moment after the pod is Ready, and a pod can be
# recreated under load: retry and re-resolve its IP on every attempt.
new_ip="$(oc -n "$NS" get pod "$NEW" -o jsonpath='{.status.podIP}' 2>/dev/null)"
new_in_endpoints() {
  new_ip="$(oc -n "$NS" get pod "$NEW" -o jsonpath='{.status.podIP}' 2>/dev/null)"
  [ -n "$new_ip" ] || return 1
  oc -n "$NS" get endpoints postgresql-r \
    -o jsonpath='{.subsets[*].addresses[*].ip}' | grep -qw "$new_ip"
}
wait_for 180 "postgresql-r includes the new replica without any Service change" new_in_endpoints

# ... and a fresh connection through postgresql-r actually lands on it.
new_serves_reads() {
  local ip
  for _ in $(seq 1 40); do
    ip="$(pod_psql_host "$PRIMARY" postgresql-r -tAc 'SELECT inet_server_addr()' 2>/dev/null)"
    [ "$ip" = "$new_ip" ] && return 0
  done
  return 1
}
check "a connection through postgresql-r lands on the new replica" new_serves_reads

# Clean up: restore the starting state.
oc -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
echo "  (restoring: replicas=$START_REPLICAS, hpa=$HAD_HPA)"
[ "$HAD_HPA" = "1" ] || oc -n "$NS" delete hpa postgresql-read --ignore-not-found >/dev/null 2>&1
oc -n "$NS" scale statefulset postgresql --replicas="$START_REPLICAS" >/dev/null
wait_for 420 "back to $START_REPLICAS Ready pods" wait_db_ready "$START_REPLICAS"

# Wait for the scaled-down pods to actually disappear first: a still-Terminating
# pod makes the orphan-PVC sweep below skip its PVC.
extra_replicas_gone() {
  ! oc -n "$NS" get pods -o name | grep -Eq 'pod/postgresql-([2-9]|[1-9][0-9]+)$'
}
wait_for 180 "the extra replicas are gone" extra_replicas_gone

# Delete only the PVCs this test created and whose pod is gone.
for pvc in $(oc -n "$NS" get pvc -o name 2>/dev/null | sed 's|.*/||' | grep '^pgdata-postgresql-'); do
  case "$PVC_BEFORE" in *"$pvc"*) continue ;; esac
  ord="${pvc##*-}"
  if ! oc -n "$NS" get pod "postgresql-$ord" >/dev/null 2>&1; then
    oc -n "$NS" delete pvc "$pvc" --ignore-not-found >/dev/null 2>&1 || true
  fi
done
check_eq "the StatefulSet is back to $START_REPLICAS replicas" "$START_REPLICAS" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}')"

t_summary
