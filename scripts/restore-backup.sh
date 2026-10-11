#!/usr/bin/env bash
#
# restore-backup.sh -- restaura un dump en una base NUEVA (no toca la base de
# la aplicacion) y muestra las tablas restauradas.
#
# Uso:
#   ./scripts/restore-backup.sh /backups/20261011-020000-appdb.dump [basededatos]
#
# Variables: KEEP_JOB=1 para no borrar el Job al terminar.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

DUMP="${1:?uso: restore-backup.sh <archivo.dump> [basededatos]}"
TARGET="${2:-restore_$(date +%s)}"
JOB="postgres-restore-$(date +%s)"
IMG="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"

echo "==> Restaurando $DUMP en la base $TARGET"
oc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  labels:
    app.kubernetes.io/name: pg-backup
    app.kubernetes.io/instance: pg-ha
    app.kubernetes.io/part-of: pg-ha
    app.kubernetes.io/component: restore
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pg-backup
        app.kubernetes.io/instance: pg-ha
        app.kubernetes.io/part-of: pg-ha
        app.kubernetes.io/component: restore
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: restore
          image: $IMG
          command: ["/bin/bash", "/scripts/restore.sh", "$DUMP", "$TARGET"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          envFrom:
            - secretRef:
                name: postgres-credentials
          env:
            - name: BACKUP_HOST
              value: postgres-rw
            - name: PGPORT
              value: "5432"
          volumeMounts:
            - name: backups
              mountPath: /backups
            - name: scripts
              mountPath: /scripts
              readOnly: true
      volumes:
        - name: backups
          persistentVolumeClaim:
            claimName: postgres-backups
        - name: scripts
          configMap:
            name: postgres-backup-scripts
            defaultMode: 0755
            items:
              - key: restore.sh
                path: restore.sh
EOF

RESULT="$(wait_job_done "$JOB" 1800)"
oc -n "$NS" logs "job/$JOB" 2>/dev/null || true
if [ "$RESULT" != "Complete" ]; then
  echo "ERROR: el restore no completo ($RESULT)." >&2
  [ "${KEEP_JOB:-0}" = "1" ] || oc -n "$NS" delete job "$JOB" >/dev/null 2>&1 || true
  exit 1
fi
[ "${KEEP_JOB:-0}" = "1" ] || oc -n "$NS" delete job "$JOB" >/dev/null 2>&1 || true
echo "Base restaurada: $TARGET"
