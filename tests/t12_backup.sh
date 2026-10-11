#!/usr/bin/env bash
# t12 -- Backups: el CronJob existe, un backup manual produce un dump valido y
#        el dump se puede restaurar en una base nueva.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t12 backups"

check "existe el CronJob postgres-backup" oc -n "$NS" get cronjob postgres-backup
check "existe el PVC postgres-backups"    oc -n "$NS" get pvc postgres-backups
check "el CronJob de backup NO comparte labels con la BD" \
  bash -c "! oc -n $NS get cronjob postgres-backup -o jsonpath='{.spec.jobTemplate.spec.template.metadata.labels}' | grep -q 'name.:.postgresql'"

PRIMARY="$(primary_pod)"
pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_backup(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="bk-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_backup(v) VALUES ('$MARK')" >/dev/null 2>&1

echo "  (backup manual)"
OUT="$("$ROOT_DIR/scripts/backup-now.sh" 2>&1 || true)"
check_contains "el backup termina OK" "[pg-backup] OK" "$OUT"
check_contains "el backup genero el archivo de globals" "-globals.sql" "$OUT"
DUMP="$(printf '%s' "$OUT" | grep -oE '[0-9]{8}-[0-9]{6}-[A-Za-z0-9_]+\.dump' | tail -1)"
check "el backup genero un dump" bash -c "[ -n '$DUMP' ]"

if [ -n "$DUMP" ]; then
  echo "  (restore de $DUMP en una base nueva)"
  TARGET="restore_test_$$"
  ROUT="$("$ROOT_DIR/scripts/restore-backup.sh" "/backups/$DUMP" "$TARGET" 2>&1 || true)"
  check_contains "el restore termina OK" "[pg-restore] OK" "$ROUT"

  CNT="$(oc -n "$NS" exec "$PRIMARY" -- env PGPASSWORD="$ADMIN_PASSWORD" \
          psql -h 127.0.0.1 -U postgres -d "$TARGET" -tAc \
          "SELECT count(*) FROM t_backup WHERE v='$MARK'" 2>/dev/null || echo 0)"
  check_eq "el backup restaurado contiene la fila de control" "1" "${CNT:-0}"

  # Con la base ya creada, el restore NO debe pisarla
  check "el restore se niega a pisar una base existente" \
    bash -c "! '$ROOT_DIR/scripts/restore-backup.sh' '/backups/$DUMP' '$TARGET' >/dev/null 2>&1"
  check "el restore se niega a usar la base de la app como destino" \
    bash -c "! '$ROOT_DIR/scripts/restore-backup.sh' '/backups/$DUMP' '$APP_DB' >/dev/null 2>&1"

  oc -n "$NS" exec "$PRIMARY" -- env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h 127.0.0.1 -U postgres -d postgres -c "DROP DATABASE IF EXISTS \"$TARGET\";" \
    >/dev/null 2>&1 || true
fi

# La retencion esta configurada
check_contains "la retencion de backups esta configurada" "BACKUP_RETENTION_DAYS" \
  "$(oc -n "$NS" get cronjob postgres-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' 2>/dev/null)"

t_summary
