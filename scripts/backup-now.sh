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

if ! oc -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=1800s >/dev/null; then
  echo "ERROR: el backup fallo. Logs:" >&2
  oc -n "$NS" logs "job/$JOB" --tail=100 >&2 || true
  exit 1
fi

oc -n "$NS" logs "job/$JOB"
oc -n "$NS" delete job "$JOB" >/dev/null 2>&1 || true
