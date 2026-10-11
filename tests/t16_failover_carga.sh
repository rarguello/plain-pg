#!/usr/bin/env bash
# t16 -- Failover con carga.
#
#   - Los datos confirmados ANTES del failover sobreviven.
#   - Lo que se pierde de esos datos es un SUFIJO contiguo (la replica iba
#     atras por un tramo final), no un conjunto disperso: eso probaria
#     divergencia, no replicacion asincrona.
#   - Al terminar hay exactamente un primary.
#
# El escritor usa ids explicitos (1000..1299) e imprime "OK <id> <epoch>" por
# cada commit confirmado. El corte es el instante en que ARRANCA el failover:
# lo confirmado antes de ese instante seguro lo escribio el primary anterior.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t16 failover bajo carga"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
IMG="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"
WRITER="t16-writer-$$"

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_load_fo(id bigint PRIMARY KEY, v text)" >/dev/null 2>&1
pod_psql "$PRIMARY" -q -c \
  "INSERT INTO t_load_fo(id, v) SELECT g, 'pre-'||g FROM generate_series(1,100) g" >/dev/null 2>&1
PRE_MAX="$(pod_psql "$PRIMARY" -tAc 'SELECT max(id) FROM t_load_fo')"
echo "  filas confirmadas antes del failover: $PRE_MAX"

# El escritor toma las credenciales por secretKeyRef (no en la spec del Job).
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
                if psql -q -c "INSERT INTO t_load_fo(id, v) VALUES (\$i, 'w-\$i') ON CONFLICT (id) DO NOTHING" >/dev/null 2>&1; then
                  echo "OK \$i \$(date +%s%N)"
                fi
                sleep 0.2
              done
          env:
            - name: PGHOST
              value: postgres-rw
            - name: PGPORT
              value: "5432"
            - name: PGUSER
              valueFrom:
                secretKeyRef: { name: postgres-credentials, key: POSTGRESQL_USER }
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef: { name: postgres-credentials, key: POSTGRESQL_PASSWORD }
            - name: PGDATABASE
              valueFrom:
                secretKeyRef: { name: postgres-credentials, key: POSTGRESQL_DATABASE }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF

sleep 6   # deja escribir unas filas antes de la caida

echo "  (failover con el escritor activo)"
TS_FENCE="$(date +%s%N)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$REPLICA" >/dev/null 2>&1 || c_fail "el failover fallo"

is_primary() { [ "$(pod_in_recovery "$1")" = "f" ]; }
wait_for 300 "$REPLICA es primary" is_primary "$REPLICA"

# Los datos confirmados antes del failover no se pierden
KEPT="$(pod_psql "$REPLICA" -tAc "SELECT count(*) FROM t_load_fo WHERE id <= $PRE_MAX" 2>/dev/null || echo 0)"
check_eq "los $PRE_MAX registros previos sobrevivieron" "$PRE_MAX" "${KEPT:-0}"

echo "  (esperando al escritor)"
wait_job_done "$WRITER" 240 >/dev/null 2>&1 || true
WLOG="$(oc -n "$NS" logs "job/$WRITER" 2>/dev/null || true)"

# "OK <id> <epoch_ns>": separo lo confirmado ANTES de que arranque el failover
# (seguro del primary anterior) de lo demas. La comparacion es lexicografica
# (mismo largo de marca) para no perder precision con numeros de 19 digitos.
ack_before() {
  local _ id ts
  while read -r _ id ts; do
    [ -n "${ts:-}" ] || continue
    if [[ "$ts" < "$TS_FENCE" ]]; then echo "$id"; fi
  done <<< "$WLOG" | sort | uniq
}
ack_after() {
  local _ id ts
  while read -r _ id ts; do
    [ -n "${ts:-}" ] || continue
    if [[ "$ts" < "$TS_FENCE" ]]; then :; else echo "$id"; fi
  done <<< "$WLOG" | sort | uniq
}
ACKED_PRE="$(ack_before)"
ACKED_POST="$(ack_after)"
PRESENT="$(pod_psql "$REPLICA" -tAc "SELECT id FROM t_load_fo WHERE id >= 1000 ORDER BY id" \
          2>/dev/null | sort | uniq)"
MISSING="$(comm -23 <(printf '%s\n' "$ACKED_PRE") <(printf '%s\n' "$PRESENT"))"

N_PRE="$(printf '%s\n' "$ACKED_PRE"  | grep -cE '^[0-9]+$' || true)"
N_POST="$(printf '%s\n' "$ACKED_POST" | grep -cE '^[0-9]+$' || true)"
N_MISS="$(printf '%s\n' "$MISSING"   | grep -cE '^[0-9]+$' || true)"
echo "  confirmados antes del failover: $N_PRE | despues: $N_POST | perdidos: $N_MISS"

# Lo perdido debe ser un sufijo contiguo de lo confirmado antes del failover.
missing_is_suffix() {
  local first_missing tail_count
  first_missing="$(printf '%s\n' "$MISSING" | grep -E '^[0-9]+$' | sort -n | head -1)"
  [ -z "$first_missing" ] && return 0
  tail_count="$(printf '%s\n' "$ACKED_PRE" | grep -E '^[0-9]+$' \
                | awk -v m="$first_missing" '$1+0 >= m+0' | wc -l)"
  [ "$tail_count" -eq "$N_MISS" ]
}
check "lo perdido es un sufijo contiguo (sin divergencia dispersa)" missing_is_suffix
check "no se perdio todo lo confirmado antes del failover" bash -c "[ $N_MISS -lt $N_PRE ]"

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
wait_for 300 "$PRIMARY vuelve a ser primary" is_primary "$PRIMARY"
wait_for 300 "$REPLICA vuelve a ser standby" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$REPLICA vuelve a ser standby" "t" "$(pod_in_recovery "$REPLICA")"

t_summary
