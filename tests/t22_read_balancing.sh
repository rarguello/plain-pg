#!/usr/bin/env bash
# t22 -- Read load balancing through postgresql-r:
#        - it selects every Ready DB instance;
#        - over many connections, the connections spread over all of them;
#        - every instance answers with the same data.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t22 read load balancing (postgresql-r)"

PRIMARY="$(primary_pod)"
mapfile -t PODS < <(db_pods)
N=40
MIN_SHARE=$((N / 10))   # each instance must get at least 10% of the connections

expected_ips() {
  local p
  for p in "${PODS[@]}"; do
    oc -n "$NS" get pod "$p" -o jsonpath='{.status.podIP}'; echo
  done | sort | tr '\n' ' '
}
EP_R="$(oc -n "$NS" get endpoints postgresql-r -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"
check_eq "postgresql-r selects every DB pod" "$(expected_ips)" "$EP_R"

# Distribute N fresh connections and count which instance answered each one.
# The loop runs inside a pod so we do not pay an oc exec per connection.
DIST="$(oc -n "$NS" exec "$PRIMARY" -- bash -c "
  for _ in \$(seq 1 $N); do
    PGPASSWORD='$ADMIN_PASSWORD' psql -h postgresql-r -U postgres -d postgres \
      -tAc 'SELECT inet_server_addr()' 2>/dev/null
  done | sort | uniq -c | awk '{print \$2\" \"\$1}'
" 2>/dev/null)"

echo "    distribution over $N connections (ip count):"
printf '%s\n' "$DIST" | sed 's/^/      /'

instances_used() { printf '%s\n' "$DIST" | grep -cE '^[0-9.]+ [0-9]+$'; }
check_eq "all instances answered at least one connection" "${#PODS[@]}" "$(instances_used)"

every_instance_gets_traffic() {
  local count
  while read -r _ count; do
    [ -n "${count:-}" ] || continue
    [ "$count" -ge "$MIN_SHARE" ] || return 1
  done <<< "$DIST"
  return 0
}
check "no instance is starved (each got >= $MIN_SHARE of $N)" every_instance_gets_traffic

# Every instance must answer with the same data (reads are consistent).
pod_psql "$PRIMARY" -q -c \
  "CREATE TABLE IF NOT EXISTS t_balance(id bigserial PRIMARY KEY, v text)" >/dev/null 2>&1
MARK="bal-$(date +%s)-$RANDOM"
pod_psql "$PRIMARY" -q -c "INSERT INTO t_balance(v) VALUES ('$MARK')" >/dev/null 2>&1

same_answer() {
  local p out
  for p in "${PODS[@]}"; do
    out="$(pod_psql "$p" -tAc "SELECT count(*) FROM t_balance WHERE v='$MARK'" 2>/dev/null)"
    [ "$out" = "1" ] || return 1
  done
  return 0
}
wait_for 30 "every instance returns the same replicated row" same_answer

t_summary
