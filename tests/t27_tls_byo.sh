#!/usr/bin/env bash
# t27 -- TLS with YOUR OWN certificate: this test generates a small PKI with
#        openssl, creates the Secret and the ConfigMap by hand, and applies
#        overlays/lab-tls-byo. Needs openssl where the tests run.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials
PRIMARY="$(primary_pod)"

echo "### t27 TLS (bring your own certificate)"

command -v openssl >/dev/null 2>&1 || {
  c_skip "openssl is not installed"
  t_summary
  exit $?
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

echo "  (generating a tiny PKI with openssl)"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=plain-pg-test-ca" \
  -keyout ca.key -out ca.crt >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=postgresql" \
  -keyout tls.key -out tls.csr >/dev/null 2>&1
cat > san.cnf <<EOF
subjectAltName=DNS:postgresql-0.postgresql-hl.plain-pg.svc,DNS:postgresql-1.postgresql-hl.plain-pg.svc,DNS:postgresql-rw.plain-pg.svc,DNS:postgresql-r.plain-pg.svc,DNS:postgresql-ro.plain-pg.svc,DNS:postgresql-hl.plain-pg.svc,DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 \
  -extfile san.cnf -out tls.crt >/dev/null 2>&1

# Apply the overlay FIRST: it drops any service-ca annotation left by t26, so
# service-ca stops managing the Secret before we write our own.
echo "  (deploying the bring-your-own overlay)"
env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" "$ROOT_DIR/manifests/overlays/lab-tls-byo" >/dev/null
wait_for 60 "the service-ca annotation is gone from postgresql-hl" bash -c \
  "! oc -n $NS get svc postgresql-hl -o jsonpath='{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}' | grep -q ."

echo "  (creating the Secret and the ConfigMap by hand)"
# t26 left a service-ca-managed ConfigMap (with the inject-cabundle annotation);
# delete both so nothing re-injects the service-ca CA over ours.
oc -n "$NS" delete configmap postgresql-tls-ca --ignore-not-found >/dev/null 2>&1
oc -n "$NS" delete secret postgresql-tls --ignore-not-found >/dev/null 2>&1
oc -n "$NS" create secret tls postgresql-tls --cert=tls.crt --key=tls.key \
  --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1
oc -n "$NS" create configmap postgresql-tls-ca --from-file=ca.crt \
  --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1

echo "  (recreating the pods to mount our certificate)"
oc -n "$NS" delete pod postgresql-1 postgresql-0 --ignore-not-found >/dev/null 2>&1
wait_for 300 "the two pods are Ready again" wait_db_ready 2

ssl_on() { [ "$(pod_psql_admin "$PRIMARY" -tAc 'SHOW ssl' 2>/dev/null)" = "on" ]; }
wait_for 60 "PostgreSQL reports ssl=on" ssl_on

repl_tls() {
  [ "$(pod_psql_admin "$PRIMARY" -tAc \
       "SELECT count(*) FROM pg_stat_ssl s JOIN pg_stat_replication r ON r.pid = s.pid WHERE s.ssl" \
       2>/dev/null)" -ge 1 ]
}
wait_for 120 "the replication connection uses TLS" repl_tls

# With our own CA we control the SANs, so a client can verify CA AND hostname.
verify_full() {
  oc -n "$NS" exec "$PRIMARY" -- env PGSSLMODE=verify-full \
    PGSSLROOTCERT=/var/lib/pgsql/data/userdata/tls/ca.crt PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h postgresql-rw.plain-pg.svc -U postgres -d postgres -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "a client verifying CA and hostname connects through -rw" verify_full

# TLS is required: a plaintext-only client must be refused.
plaintext_refused() {
  ! oc -n "$NS" exec "$PRIMARY" -- env PGSSLMODE=disable PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h postgresql-rw -U postgres -d postgres -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "a plaintext-only client is refused" plaintext_refused

t_summary
