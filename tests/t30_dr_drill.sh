#!/usr/bin/env bash
# t30 -- Disaster recovery drill: the PGDATA PVCs are lost, the cluster is rebuilt
#        from scratch and the last dump is loaded back into the application
#        database (FORCE=1). That is the recovery path documented in
#        operations.md. Destructive: it deletes the StatefulSet and both PGDATA
#        PVCs (the backups PVC survives).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t30 disaster recovery drill"

PRIMARY="$(primary_pod)"

echo "  (control row, then a backup of the application database)"
pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_dr(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="dr-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_dr(v) VALUES ('$MARK')" >/dev/null 2>&1

OUT="$("$ROOT_DIR/scripts/backup-now.sh" 2>&1 || true)"
check_contains "the backup ends OK" "[pg-backup] OK" "$OUT"
DUMP="$(printf '%s' "$OUT" | grep -oE '[0-9]{8}-[0-9]{6}-[A-Za-z0-9_]+\.dump' | tail -1)"
check "the backup generated a dump" bash -c "[ -n '$DUMP' ]"

echo "  (disaster: deleting the StatefulSet and both PGDATA PVCs)"
oc -n "$NS" delete statefulset postgresql --wait=true >/dev/null 2>&1 || true
oc -n "$NS" delete pvc pgdata-postgresql-0 pgdata-postgresql-1 --wait=true >/dev/null 2>&1 || true
check "no PGDATA PVC remains" \
  bash -c "! oc -n $NS get pvc pgdata-postgresql-0 >/dev/null 2>&1"
check "the backups PVC survives" oc -n "$NS" get pvc postgresql-backups

echo "  (rebuilding from scratch)"
if NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh" >/dev/null 2>&1; then
  c_ok "deploy.sh rebuilds the cluster"
else
  c_fail "deploy.sh failed on the rebuild"
fi
wait_for 300 "the two pods are Ready again" wait_db_ready 2
check_eq "replication is active after the rebuild" "1" \
  "$(streaming_count "$(primary_pod)")"

if [ -n "$DUMP" ]; then
  echo "  (restoring $DUMP into $APP_DB with FORCE=1)"
  ROUT="$(FORCE=1 "$ROOT_DIR/scripts/restore-backup.sh" "/backups/$DUMP" "$APP_DB" 2>&1 || true)"
  check_contains "the restore ends OK" "[pg-restore] OK" "$ROUT"
  check_eq "the control row is back in the application database" "1" \
    "$(pod_psql "$(primary_pod)" -tAc "SELECT count(*) FROM t_dr WHERE v='$MARK'" 2>/dev/null || echo 0)"
  check_eq "the restored table is owned by the application user" "$APP_USER" \
    "$(pod_psql "$(primary_pod)" -tAc \
       "SELECT pg_get_userbyid(c.relowner) FROM pg_class c \
          JOIN pg_namespace n ON n.oid = c.relnamespace \
         WHERE c.relname='t_dr' AND n.nspname='public'" 2>/dev/null || echo '')"
else
  c_fail "no dump to restore"
fi

t_summary
