#!/usr/bin/env bash
#
# backup-now.sh -- lanza un backup manual (mismo Job que el CronJob) y espera.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

JOB="postgres-backup-manual-$(date +%s)"

echo "==> Creando Job $JOB a partir del CronJob postgres-backup"
oc -n "$NS" create job "$JOB" --from=cronjob/postgres-backup >/dev/null

RESULT="$(wait_job_done "$JOB" 1800)"
oc -n "$NS" logs "job/$JOB" 2>/dev/null || true
if [ "$RESULT" != "Complete" ]; then
  echo "ERROR: el backup no completo ($RESULT)." >&2
  exit 1
fi
oc -n "$NS" delete job "$JOB" >/dev/null 2>&1 || true
