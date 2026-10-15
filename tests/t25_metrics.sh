#!/usr/bin/env bash
# t25 -- metrics: postgres_exporter serves PostgreSQL metrics through its
#        Service. Needs the monitoring.coreos.com CRDs (OpenShift monitoring);
#        skips on a cluster without them (e.g. MicroShift).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t25 metrics exporter"

if ! oc get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  c_skip "no monitoring.coreos.com CRDs on this cluster"
  t_summary
  exit $?
fi

echo "  (deploying the metrics component)"
env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" "$ROOT_DIR/manifests/overlays/lab-metrics" >/dev/null

check "the exporter Deployment becomes Available" \
  oc -n "$NS" wait --for=condition=Available deployment/postgresql-metrics --timeout=180s
check "the metrics Service exists" oc -n "$NS" get svc postgresql-metrics
check "the ServiceMonitor exists" oc -n "$NS" get servicemonitor postgresql

# The exporter must actually reach the database (it connects through -rw, so it
# follows a failover). Query /metrics through the API server proxy.
metrics_up() {
  oc get --raw "/api/v1/namespaces/$NS/services/postgresql-metrics:9187/proxy/metrics" 2>/dev/null \
    | grep -qx 'pg_up 1'
}
wait_for 120 "the exporter reports pg_up 1 (it reached the primary)" metrics_up
check "the exporter exposes a database size metric" bash -c \
  "oc get --raw '/api/v1/namespaces/$NS/services/postgresql-metrics:9187/proxy/metrics' 2>/dev/null | grep -q '^pg_database_size_bytes'"

# It connects as the application user, which the entrypoint grants pg_monitor.
check_eq "the app user is a member of pg_monitor" "t" \
  "$(pod_psql_admin "$(primary_pod)" -tAc "SELECT pg_has_role('$APP_USER', 'pg_monitor', 'member')" 2>/dev/null)"

t_summary
