#!/usr/bin/env bash
# t26 -- TLS: the service-ca component makes PostgreSQL serve TLS and the
#        replication connection uses it. Needs the service-ca controller
#        (OpenShift/MicroShift); skips on a cluster without it.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t26 TLS (service-ca)"

if ! oc -n openshift-service-ca get deploy service-ca >/dev/null 2>&1; then
  c_skip "no service-ca controller on this cluster"
  t_summary
  exit $?
fi

echo "  (deploying the tls component)"
# Start from a clean TLS state. A previous test may have left its own
# Secret/ConfigMap (bring-your-own) and, worse, deleting the service-ca Secret
# makes service-ca refuse to re-issue it (it records a generation error). So
# clear the error annotations and the serving-cert annotation first; the overlay
# re-adds the latter, which triggers a fresh issuance.
oc -n "$NS" annotate svc postgresql-hl \
  service.beta.openshift.io/serving-cert-generation-error- \
  service.alpha.openshift.io/serving-cert-generation-error- \
  service.beta.openshift.io/serving-cert-generation-error-num- \
  service.alpha.openshift.io/serving-cert-generation-error-num- \
  service.beta.openshift.io/serving-cert-secret-name- >/dev/null 2>&1 || true
oc -n "$NS" delete configmap postgresql-tls-ca --ignore-not-found >/dev/null 2>&1
oc -n "$NS" delete secret postgresql-tls --ignore-not-found >/dev/null 2>&1
env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" "$ROOT_DIR/manifests/overlays/lab-tls" >/dev/null

wait_for 120 "the service-ca issues the certificate" \
  bash -c "oc -n $NS get secret postgresql-tls >/dev/null 2>&1"
wait_for 60 "the CA bundle is injected into the ConfigMap" \
  bash -c "oc -n $NS get cm postgresql-tls-ca -o jsonpath='{.data.service-ca\.crt}' | grep -q BEGIN"

# updateStrategy is OnDelete, so the pods must be recreated to mount the cert.
echo "  (recreating the pods to mount the certificate)"
oc -n "$NS" delete pod postgresql-1 postgresql-0 --ignore-not-found >/dev/null 2>&1
wait_for 300 "the two pods are Ready again" wait_db_ready 2

ssl_on() { [ "$(pod_psql_admin postgresql-0 -tAc 'SHOW ssl' 2>/dev/null)" = "on" ]; }
wait_for 60 "PostgreSQL reports ssl=on" ssl_on

# The replica's WAL connection must be encrypted.
repl_tls() {
  [ "$(pod_psql_admin postgresql-0 -tAc \
       "SELECT count(*) FROM pg_stat_ssl s JOIN pg_stat_replication r ON r.pid = s.pid WHERE s.ssl" \
       2>/dev/null)" -ge 1 ]
}
wait_for 120 "the replication connection uses TLS" repl_tls

# A client that verifies the CA connects through -rw.
verify_ca() {
  oc -n "$NS" exec postgresql-0 -- env PGSSLMODE=verify-ca \
    PGSSLROOTCERT=/var/lib/pgsql/data/userdata/tls/ca.crt PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h postgresql-rw -U postgres -d postgres -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "a client that verifies the CA connects through -rw" verify_ca

t_summary
