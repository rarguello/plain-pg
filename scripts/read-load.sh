#!/usr/bin/env bash
#
# read-load.sh -- generate read load against postgresql-r and watch the HPA.
#
# Usage:
#   ./scripts/read-load.sh [seconds] [clients]     # defaults: 180 12
#
# It uses a dedicated database (`pgbench` by default, owned by the app user),
# initialized only if the pgbench tables are missing, and then runs a
# select-only pgbench Job against the postgresql-r Service. It exits non-zero
# if the load Job fails or times out.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_credentials

SECONDS_LOAD="${1:-180}"
CLIENTS="${2:-12}"
BENCH_DB="${BENCH_DB:-pgbench}"
JOB="pgbench-read-$(date +%s)"
IMG="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"

echo "==> Benchmark database: $BENCH_DB"
if [ "$(pod_psql_admin "$(primary_pod)" -tAc "SELECT count(*) FROM pg_database WHERE datname='$BENCH_DB'")" = "0" ]; then
  echo "    creating it (owner: $APP_USER)"
  oc -n "$NS" exec "$(primary_pod)" -- env PGPASSWORD="$ADMIN_PASSWORD" psql \
    -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"$BENCH_DB\" OWNER \"$APP_USER\";" >/dev/null
fi

bench_tables_exist() {
  oc -n "$NS" exec "$(primary_pod)" -- env PGPASSWORD="$ADMIN_PASSWORD" psql \
    -h 127.0.0.1 -U postgres -d "$BENCH_DB" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_name='pgbench_accounts'" 2>/dev/null | grep -qx 1
}
if bench_tables_exist; then
  echo "    pgbench tables already present; not re-initializing"
else
  echo "    initializing pgbench tables"
  oc -n "$NS" exec "$(primary_pod)" -- env PGPASSWORD="$APP_PASSWORD" \
    pgbench -i -q -s 1 -h postgresql-rw -U "$APP_USER" -d "$BENCH_DB" >/dev/null \
    || { echo "ERROR: pgbench initialization failed" >&2; exit 1; }
fi

echo "==> Starting $CLIENTS read clients for ${SECONDS_LOAD}s against postgresql-r"
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
  activeDeadlineSeconds: $((SECONDS_LOAD + 120))
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
          command:
            - pgbench
            - -S
            - -c
            - "$CLIENTS"
            - -j
            - "4"
            - -T
            - "$SECONDS_LOAD"
            - -h
            - postgresql-r
            - -U
            - "$APP_USER"
            - -d
            - "$BENCH_DB"
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef: { name: postgresql-credentials, key: POSTGRESQL_PASSWORD }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF

if ! oc -n "$NS" get hpa postgresql-read >/dev/null 2>&1; then
  echo "    (no HPA deployed; run this with manifests/overlays/ha-autoscale)"
fi

RESULT=Timeout
while [ "$RESULT" = "Timeout" ]; do
  RESULT="$(wait_job_done "$JOB" 15)"
  oc -n "$NS" get hpa postgresql-read 2>/dev/null || true
  oc -n "$NS" get pods \
    -l app.kubernetes.io/name=postgresql,app.kubernetes.io/component=database \
    --no-headers 2>/dev/null | awk '{print "    pod "$1" "$2}' || true
done

echo "==> pgbench summary"
oc -n "$NS" logs "job/$JOB" 2>/dev/null | tail -12 || true
oc -n "$NS" delete job "$JOB" >/dev/null 2>&1 || true

if [ "$RESULT" != "Complete" ]; then
  echo "ERROR: the read load did not complete ($RESULT)" >&2
  exit 1
fi
