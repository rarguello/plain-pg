#!/usr/bin/env bash
#
# backup-now.sh -- launches a manual backup (same Job as the CronJob) and waits.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

JOB="postgresql-backup-manual-$(date +%s)"

echo "==> Creating Job $JOB from CronJob postgresql-backup"
oc -n "$NS" create job "$JOB" --from=cronjob/postgresql-backup >/dev/null

RESULT="$(wait_job_done "$JOB" 1800)"
oc -n "$NS" logs "job/$JOB" 2>/dev/null || true
if [ "$RESULT" != "Complete" ]; then
  echo "ERROR: the backup did not complete ($RESULT)." >&2
  exit 1
fi
oc -n "$NS" delete job "$JOB" >/dev/null 2>&1 || true
