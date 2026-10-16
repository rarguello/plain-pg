#!/usr/bin/env bash
# t32 -- Single instance + TLS: overlays/single-tls runs one pod that
#        requires TLS, with the certificate issued by OpenShift's service-ca.
#        Needs the service-ca controller; skips without it.
#        Destructive: it changes the topology and the TLS state (restored).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t32 single instance + TLS (service-ca)"

if ! oc -n openshift-service-ca get deploy service-ca >/dev/null 2>&1; then
  c_skip "no service-ca controller on this cluster"
  t_summary
  exit $?
fi

echo "  (applying overlays/single-tls)"
# Same clean-up as t26: a previous test may have left its own Secret/ConfigMap
# and service-ca records a generation error when the Secret is deleted.
oc -n "$NS" annotate svc postgresql-hl \
  service.beta.openshift.io/serving-cert-generation-error- \
  service.alpha.openshift.io/serving-cert-generation-error- \
  service.beta.openshift.io/serving-cert-generation-error-num- \
  service.alpha.openshift.io/serving-cert-generation-error-num- \
  service.beta.openshift.io/serving-cert-secret-name- >/dev/null 2>&1 || true
oc -n "$NS" delete configmap postgresql-tls-ca --ignore-not-found >/dev/null 2>&1
oc -n "$NS" delete secret postgresql-tls --ignore-not-found >/dev/null 2>&1
oc -n "$NS" delete svc postgresql-ro --ignore-not-found >/dev/null 2>&1
oc -n "$NS" delete cronjob postgresql-failover --ignore-not-found >/dev/null 2>&1
oc apply -k "$ROOT_DIR/manifests/overlays/single-tls" >/dev/null 2>&1 \
  || c_fail "applying overlays/single-tls failed"

wait_for 120 "the service-ca issues the certificate" \
  bash -c "oc -n $NS get secret postgresql-tls >/dev/null 2>&1"
wait_for 60 "the CA bundle is injected into the ConfigMap" \
  bash -c "oc -n $NS get cm postgresql-tls-ca -o jsonpath='{.data.service-ca\.crt}' | grep -q BEGIN"

echo "  (recreating the pod to mount the certificate)"
oc -n "$NS" delete pod postgresql-0 --ignore-not-found >/dev/null 2>&1
wait_for 300 "the single pod is Ready again" wait_db_ready 1

check_eq "still exactly one database pod" "1" "$(db_pods | wc -l | tr -d ' ')"
check_eq "it is the primary" "f" "$(pod_in_recovery "$(primary_pod)")"
check "there is no replica Service" bash -c "! oc -n $NS get svc postgresql-ro >/dev/null 2>&1"

ssl_on() { [ "$(pod_psql_admin "$(primary_pod)" -tAc 'SHOW ssl' 2>/dev/null)" = "on" ]; }
wait_for 60 "PostgreSQL reports ssl=on" ssl_on

verify_ca() {
  oc -n "$NS" exec "$(primary_pod)" -- env PGSSLMODE=verify-ca \
    PGSSLROOTCERT=/var/lib/pgsql/data/userdata/tls/ca.crt PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h postgresql-rw -U postgres -d postgres -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "a client that verifies the CA connects through -rw" verify_ca

plaintext_refused() {
  ! oc -n "$NS" exec "$(primary_pod)" -- env PGSSLMODE=disable PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h postgresql-rw -U postgres -d postgres -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "a plaintext-only client is refused" plaintext_refused

echo "  (restoring the full lab overlay, without TLS)"
oc apply -k "$ROOT_DIR/manifests/overlays/ha" >/dev/null 2>&1 \
  || c_fail "applying overlays/ha failed"
oc -n "$NS" delete pod postgresql-1 postgresql-0 --ignore-not-found >/dev/null 2>&1
wait_for 300 "two pods are Ready again" wait_db_ready 2
check_eq "the second pod is a standby" "t" "$(pod_in_recovery "$(replica_pods | head -1)")"
streaming() { [ "$(streaming_count "$(primary_pod)")" = "1" ]; }
wait_for 180 "replication resumes without TLS" streaming

t_summary
