#!/usr/bin/env bash
# t16 -- Failover under load.
#
#   - Data confirmed BEFORE the failover survives.
#   - What is lost from that data is a contiguous SUFFIX (the replica was behind
#     by a final stretch), not a scattered set: that would prove divergence, not
#     asynchronous replication.
#   - At the end there is exactly one primary.
#
# The writer uses explicit ids (1000..1299) and prints "OK <id> <epoch>" for
# each confirmed commit. The cut is the instant at which the failover STARTS:
# what was confirmed before that instant was surely written by the previous
# primary.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t16 failover under load"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
IMG="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
WRITER="t16-writer-$$"

pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_load_fo(id bigint PRIMARY KEY, v text)" >/dev/null 2>&1
pod_psql "$PRIMARY" -q -c \
  "INSERT INTO t_load_fo(id, v) SELECT g, 'pre-'||g FROM generate_series(1,100) g" >/dev/null 2>&1
PRE_MAX="$(pod_psql "$PRIMARY" -tAc 'SELECT max(id) FROM t_load_fo')"
echo "  rows confirmed before the failover: $PRE_MAX"

# The writer takes the credentials via secretKeyRef (not in the Job spec).
oc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $WRITER
  labels:
    app.kubernetes.io/name: pg-load
    app.kubernetes.io/instance: plain-pg
    app.kubernetes.io/part-of: plain-pg
    app.kubernetes.io/component: test
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pg-load
        app.kubernetes.io/instance: plain-pg
        app.kubernetes.io/part-of: plain-pg
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
              value: postgresql-rw
            - name: PGPORT
              value: "5432"
            - name: PGUSER
              valueFrom:
                secretKeyRef: { name: postgresql-credentials, key: POSTGRESQL_USER }
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef: { name: postgresql-credentials, key: POSTGRESQL_PASSWORD }
            - name: PGDATABASE
              valueFrom:
                secretKeyRef: { name: postgresql-credentials, key: POSTGRESQL_DATABASE }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF

sleep 6   # let a few rows be written before the failure

echo "  (failover with the writer active)"
TS_FENCE="$(date +%s%N)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$REPLICA" >/dev/null 2>&1 || c_fail "the failover failed"

is_primary() { [ "$(pod_in_recovery "$1")" = "f" ]; }
wait_for 300 "$REPLICA is primary" is_primary "$REPLICA"

# Data confirmed before the failover is not lost
KEPT="$(pod_psql "$REPLICA" -tAc "SELECT count(*) FROM t_load_fo WHERE id <= $PRE_MAX" 2>/dev/null || echo 0)"
check_eq "the $PRE_MAX previous records survived" "$PRE_MAX" "${KEPT:-0}"

echo "  (waiting for the writer)"
wait_job_done "$WRITER" 240 >/dev/null 2>&1 || true
WLOG="$(oc -n "$NS" logs "job/$WRITER" 2>/dev/null || true)"

# "OK <id> <epoch_ns>": separate what was confirmed BEFORE the failover starts
# (surely from the previous primary) from the rest. The comparison is
# lexicographic (same stamp length) so as not to lose precision with 19-digit
# numbers.
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
echo "  confirmed before the failover: $N_PRE | after: $N_POST | lost: $N_MISS"

# What is lost must be a contiguous suffix of what was confirmed before the failover.
missing_is_suffix() {
  local first_missing tail_count
  first_missing="$(printf '%s\n' "$MISSING" | grep -E '^[0-9]+$' | sort -n | head -1)"
  [ -z "$first_missing" ] && return 0
  tail_count="$(printf '%s\n' "$ACKED_PRE" | grep -E '^[0-9]+$' \
                | awk -v m="$first_missing" '$1+0 >= m+0' | wc -l)"
  [ "$tail_count" -eq "$N_MISS" ]
}
check "what is lost is a contiguous suffix (no scattered divergence)" missing_is_suffix
check "not all data confirmed before the failover was lost" bash -c "[ $N_MISS -lt $N_PRE ]"

# A single primary in the cluster
PRIMARIES=0
for p in $(db_pods); do [ "$(pod_in_recovery "$p")" = "f" ] && PRIMARIES=$((PRIMARIES + 1)); done
check_eq "exactly one pod is primary at the end" "1" "$PRIMARIES"

# The application can write again through the Service
MARK="post-fo-$(date +%s)"
pod_psql "$REPLICA" -q -c "INSERT INTO t_load_fo(id, v) VALUES (9999, '$MARK')" >/dev/null 2>&1
check_eq "the database can be written to after the failover" "1" \
  "$(pod_psql "$REPLICA" -tAc "SELECT count(*) FROM t_load_fo WHERE v='$MARK'" 2>/dev/null || echo 0)"

oc -n "$NS" delete job "$WRITER" --ignore-not-found >/dev/null 2>&1 || true

echo "  (failback)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$PRIMARY" >/dev/null 2>&1 || c_fail "the failback failed"
wait_for 300 "$PRIMARY is primary again" is_primary "$PRIMARY"
wait_for 300 "$REPLICA is standby again" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$REPLICA is standby again" "t" "$(pod_in_recovery "$REPLICA")"

t_summary
