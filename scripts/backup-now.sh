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

if ! oc -n "$NS" wait --for=condition=complete --for=condition=failed \
        "job/$JOB" --timeout=1800s >/dev/null 2>&1; then
  echo "ERROR: el backup no termino a tiempo. Logs:" >&2
  oc -n "$NS" logs "job/$JOB" --tail=100 >&2 || true
  exit 1
fi

DONE="$(oc -n "$NS" get job "$JOB" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
oc -n "$NS" logs "job/$JOB" || true
if [ "$DONE" != "True" ]; then
  echo "ERROR: el backup fallo." >&2
  exit 1
fi
oc -n "$NS" delete job "$JOB" >/dev/null 2>&1 || true
