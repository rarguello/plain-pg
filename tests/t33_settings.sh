#!/usr/bin/env bash
# t33 -- Settings: components/settings applies postgresql.conf settings through
#        postgresql.auto.conf (postgresql.conf is never edited) and inserts extra
#        pg_hba rules before the image's catch-all rules, so they win.
#        Destructive: it changes the manifests and restarts the pods.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t33 settings and pg_hba"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"

echo "  (deploying the settings component with real values)"
oc apply -k "$ROOT_DIR/manifests/overlays/ha-settings" >/dev/null 2>&1 \
  || c_fail "applying overlays/ha-settings failed"
oc -n "$NS" patch configmap postgresql-settings --type merge -p \
  '{"data":{"settings.conf":"work_mem = '"'"'17MB'"'"'\n"}}' >/dev/null
# `reject` for every non-replication remote connection, in plaintext (the lab
# has no TLS): it only takes effect if our rule is evaluated before the image's
# catch-all (md5).
oc -n "$NS" patch configmap postgresql-hba --type merge -p \
  '{"data":{"extra.conf":"host all all all reject\n"}}' >/dev/null
oc -n "$NS" delete pod postgresql-0 postgresql-1 --ignore-not-found >/dev/null 2>&1
wait_for 300 "the two pods are Ready again" wait_db_ready 2

check_eq "the setting is in effect (work_mem)" "17MB" \
  "$(pod_psql_admin "$PRIMARY" -tAc 'SHOW work_mem' 2>/dev/null)"
check "postgresql.conf itself was not edited" bash -c \
  "! oc -n $NS exec $PRIMARY -- grep -qE '^[[:space:]]*work_mem' $PGDATA_PATH/postgresql.conf"
check_contains "postgresql.auto.conf includes our settings file" "plain-pg-settings.conf" \
  "$(oc -n "$NS" exec "$PRIMARY" -- grep -F 'plain-pg-settings.conf' "$PGDATA_PATH/postgresql.auto.conf" 2>/dev/null)"

HBA="$(oc -n "$NS" exec "$PRIMARY" -- grep -nE '^(host|hostssl|hostnossl)' "$PGDATA_PATH/pg_hba.conf" 2>/dev/null)"
REJECT_LINE="$(printf '%s\n' "$HBA" | grep -F 'reject' | head -1 | cut -d: -f1)"
# The image's catch-all is the LAST `all all all` line: ours is inserted before it.
CATCHALL_LINE="$(printf '%s\n' "$HBA" | grep -F 'all all all' | tail -1 | cut -d: -f1)"
check "the extra rule is in pg_hba.conf" bash -c "[ -n '$REJECT_LINE' ]"
check "it comes before the image's catch-all" bash -c \
  "[ -n '$CATCHALL_LINE' ] && [ '$REJECT_LINE' -lt '$CATCHALL_LINE' ]"

# The rule wins: a remote connection is rejected, replication keeps working
# (replication matches the replication rules, which `all` does not cover).
remote_rejected() {
  ! oc -n "$NS" exec "$REPLICA" -- env PGPASSWORD="$APP_PASSWORD" \
    psql -h postgresql-rw -U "$APP_USER" -d "$APP_DB" -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "a remote connection is rejected by our rule" remote_rejected
check_eq "the local connection still works" "1" \
  "$(pod_psql_admin "$PRIMARY" -tAc 'SELECT 1' 2>/dev/null)"
streaming() { [ "$(streaming_count "$PRIMARY")" = "1" ]; }
wait_for 120 "replication is unaffected" streaming

echo "  (the documented example: replacing the image's md5 with scram-sha-256)"
oc -n "$NS" patch configmap postgresql-hba --type merge -p \
  '{"data":{"extra.conf":"host all all all scram-sha-256\n"}}' >/dev/null
oc -n "$NS" delete pod postgresql-0 postgresql-1 --ignore-not-found >/dev/null 2>&1
wait_for 300 "the two pods are Ready again" wait_db_ready 2

NEW_PRIMARY="$(primary_pod)"
check_contains "pg_hba_file_rules reports our rule as scram-sha-256" "scram-sha-256" \
  "$(pod_psql_admin "$NEW_PRIMARY" -tAc \
     "SELECT auth_method FROM pg_hba_file_rules WHERE address = 'all' ORDER BY line_number LIMIT 1" 2>/dev/null)"
remote_scram_ok() {
  oc -n "$NS" exec "$NEW_PRIMARY" -- env PGPASSWORD="$APP_PASSWORD" \
    psql -h postgresql-rw -U "$APP_USER" -d "$APP_DB" -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "a remote connection authenticates with it" remote_scram_ok

echo "  (removing the component)"
oc apply -k "$ROOT_DIR/manifests/overlays/ha" >/dev/null 2>&1 \
  || c_fail "re-applying overlays/ha failed"
oc -n "$NS" delete pod postgresql-0 postgresql-1 --ignore-not-found >/dev/null 2>&1
wait_for 300 "the two pods are Ready again" wait_db_ready 2

NEW_PRIMARY="$(primary_pod)"
check_ne "the setting is gone" "17MB" \
  "$(pod_psql_admin "$NEW_PRIMARY" -tAc 'SHOW work_mem' 2>/dev/null)"
check "the extra pg_hba block is gone" bash -c \
  "! oc -n $NS exec $NEW_PRIMARY -- grep -qF 'plain-pg: extra pg_hba rules' $PGDATA_PATH/pg_hba.conf"
remote_ok() {
  oc -n "$NS" exec "$NEW_PRIMARY" -- env PGPASSWORD="$APP_PASSWORD" \
    psql -h postgresql-rw -U "$APP_USER" -d "$APP_DB" -tAc 'SELECT 1' 2>/dev/null | grep -qx 1
}
check "a remote connection works again" remote_ok

t_summary
