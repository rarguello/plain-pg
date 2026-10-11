#!/usr/bin/env bash
# t12 -- Backups: the CronJob exists, a manual backup produces a valid dump and
#        the dump can be restored into a new database.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t12 backups"

check "CronJob postgresql-backup exists" oc -n "$NS" get cronjob postgresql-backup
check "PVC postgresql-backups exists"    oc -n "$NS" get pvc postgresql-backups
check "the backup CronJob does NOT share labels with the DB" \
  bash -c "! oc -n $NS get cronjob postgresql-backup -o jsonpath='{.spec.jobTemplate.spec.template.metadata.labels}' | grep -q 'name.:.postgresql'"

PRIMARY="$(primary_pod)"
pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_backup(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="bk-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_backup(v) VALUES ('$MARK')" >/dev/null 2>&1

echo "  (backup manual)"
OUT="$("$ROOT_DIR/scripts/backup-now.sh" 2>&1 || true)"
check_contains "the backup ends OK" "[pg-backup] OK" "$OUT"
check_contains "the backup generated the globals file" "-globals.sql" "$OUT"
DUMP="$(printf '%s' "$OUT" | grep -oE '[0-9]{8}-[0-9]{6}-[A-Za-z0-9_]+\.dump' | tail -1)"
check "the backup generated a dump" bash -c "[ -n '$DUMP' ]"

if [ -n "$DUMP" ]; then
  echo "  (restore of $DUMP into a new database)"
  TARGET="restore_test_$$"
  ROUT="$("$ROOT_DIR/scripts/restore-backup.sh" "/backups/$DUMP" "$TARGET" 2>&1 || true)"
  check_contains "the restore ends OK" "[pg-restore] OK" "$ROUT"

  CNT="$(oc -n "$NS" exec "$PRIMARY" -- env PGPASSWORD="$ADMIN_PASSWORD" \
          psql -h 127.0.0.1 -U postgres -d "$TARGET" -tAc \
          "SELECT count(*) FROM t_backup WHERE v='$MARK'" 2>/dev/null || echo 0)"
  check_eq "the restored backup contains the control row" "1" "${CNT:-0}"

  # With the database already created, the restore must NOT overwrite it
  check "the restore refuses to overwrite an existing database" \
    bash -c "! '$ROOT_DIR/scripts/restore-backup.sh' '/backups/$DUMP' '$TARGET' >/dev/null 2>&1"
  check "the restore refuses to use the app database as target" \
    bash -c "! '$ROOT_DIR/scripts/restore-backup.sh' '/backups/$DUMP' '$APP_DB' >/dev/null 2>&1"

  oc -n "$NS" exec "$PRIMARY" -- env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h 127.0.0.1 -U postgres -d postgres -c "DROP DATABASE IF EXISTS \"$TARGET\";" \
    >/dev/null 2>&1 || true
fi

# Retention is configured
check_contains "backup retention is configured" "BACKUP_RETENTION_DAYS" \
  "$(oc -n "$NS" get cronjob postgresql-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' 2>/dev/null)"

t_summary
