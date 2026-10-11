#!/usr/bin/env bash
# t16 -- Failover con carga: los datos confirmados ANTES del failover
#        sobreviven, la perdida por la ventana asincrona queda acotada, y al
#        terminar hay un solo primary.
#
# El escritor usa ids explicitos (1000..1299) e imprime "OK <id>" por cada
# commit confirmado. Al final se compara el ultimo id confirmado con el maximo
# presente en el nuevo primary: la diferencia es lo perdido por la ventana
# asincrona (con replicacion asincrona, un failover puede perder las ultimas
# transacciones no replicadas; se acota, no se exige cero).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t16 failover bajo carga"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
IMG="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"
WRITER="t16-writer-$$"
LOST_MAX=20

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_load_fo(id bigint PRIMARY KEY, v text)" >/dev/null 2>&1
pod_psql "$PRIMARY" -q -c \
  "INSERT INTO t_load_fo(id, v) SELECT g, 'pre-'||g FROM generate_series(1,100) g" >/dev/null 2>&1
PRE_MAX="$(pod_psql "$PRIMARY" -tAc 'SELECT max(id) FROM t_load_fo')"
echo "  filas confirmadas antes del failover: $PRE_MAX"

oc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $WRITER
  labels:
    app.kubernetes.io/name: pg-backup
    app.kubernetes.io/instance: pg-ha
    app.kubernetes.io/component: test
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pg-backup
        app.kubernetes.io/instance: pg-ha
        app.kubernetes.io/component: test
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: writer
          image: $IMG
          command: ["/bin/bash", "-c"]
          args:
            - |
              for i in \$(seq 1000 1299); do
                if PGPASSWORD="$APP_PASSWORD" psql -h postgres-rw -U "$APP_USER" -d "$APP_DB" \
                     -q -c "INSERT INTO t_load_fo(id, v) VALUES (\$i, 'w-\$i') ON CONFLICT (id) DO NOTHING" >/dev/null 2>&1; then
                  echo "OK \$i"
                fi
                sleep 0.2
              done
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF

sleep 6   # deja escribir unas filas antes de la caida

echo "  (failover con el escritor activo)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$REPLICA" >/dev/null 2>&1 || c_fail "el failover fallo"

wait_for 300 "$REPLICA es primary" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "el nuevo primary responde como primary" "f" "$(pod_in_recovery "$REPLICA")"

# Los datos confirmados antes del failover no se pierden
KEPT="$(pod_psql "$REPLICA" -tAc "SELECT count(*) FROM t_load_fo WHERE id <= $PRE_MAX" 2>/dev/null || echo 0)"
check_eq "los $PRE_MAX registros previos sobrevivieron" "$PRE_MAX" "${KEPT:-0}"

# Esperar a que el escritor termine y medir la ventana asincrona
echo "  (esperando al escritor)"
oc -n "$NS" wait --for=condition=complete "job/$WRITER" --timeout=240s >/dev/null 2>&1 || true
WLOG="$(oc -n "$NS" logs "job/$WRITER" 2>/dev/null || true)"
ACKED="$(printf '%s\n' "$WLOG" | grep -oE '^OK [0-9]+' | awk '{print $2}' | sort -n | tail -1)"
ACKED="${ACKED:-0}"
PRESENT="$(pod_psql "$REPLICA" -tAc "SELECT COALESCE(max(id),0) FROM t_load_fo WHERE id >= 1000" 2>/dev/null || echo 0)"
PRESENT="${PRESENT:-0}"
LOST=$((ACKED - PRESENT))
echo "  commits confirmados por el escritor: $ACKED | presentes en el nuevo primary: $PRESENT | perdidos: $LOST"
check "la perdida por la ventana asincrona esta acotada (<= $LOST_MAX)" \
  bash -c "[ $LOST -le $LOST_MAX ]"

# Un solo primary en el cluster
PRIMARIES=0
for p in $(db_pods); do [ "$(pod_in_recovery "$p")" = "f" ] && PRIMARIES=$((PRIMARIES + 1)); done
check_eq "exactamente un pod es primary al terminar" "1" "$PRIMARIES"

# La aplicacion puede volver a escribir por el Service
MARK="post-fo-$(date +%s)"
pod_psql "$REPLICA" -q -c "INSERT INTO t_load_fo(id, v) VALUES (9999, '$MARK')" >/dev/null 2>&1
check_eq "se puede escribir en la base tras el failover" "1" \
  "$(pod_psql "$REPLICA" -tAc "SELECT count(*) FROM t_load_fo WHERE v='$MARK'" 2>/dev/null || echo 0)"

oc -n "$NS" delete job "$WRITER" --ignore-not-found >/dev/null 2>&1 || true

echo "  (failback)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$PRIMARY" >/dev/null 2>&1 || c_fail "el failback fallo"
check_eq "$PRIMARY vuelve a ser primary" "f" "$(pod_in_recovery "$PRIMARY")"
wait_for 300 "$REPLICA vuelve a ser standby" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$REPLICA vuelve a ser standby" "t" "$(pod_in_recovery "$REPLICA")"

t_summary
