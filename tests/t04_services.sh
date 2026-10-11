#!/usr/bin/env bash
# t04 -- Services and DNS: -rw/-r/-ro/-hl point at the right pods.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t04 services and DNS"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
IP0="$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.status.podIP}')"
IP1="$(oc -n "$NS" get pod "$REPLICA" -o jsonpath='{.status.podIP}')"

EP_RW="$(oc -n "$NS" get endpoints postgresql-rw -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
EP_RO="$(oc -n "$NS" get endpoints postgresql-ro -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
EP_R="$(oc -n "$NS" get endpoints postgresql-r -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"
EP_HL="$(oc -n "$NS" get endpoints postgresql-hl -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"

check_eq "postgresql-rw points only at the primary" "$IP0" "$EP_RW"
check_eq "postgresql-ro points only at the replica" "$IP1" "$EP_RO"
check_eq "postgresql-r includes every Ready DB pod" \
  "$(printf '%s\n%s\n' "$IP0" "$IP1" | sort | tr '\n' ' ')" "$EP_R"
check_eq "postgresql-hl has exactly the 2 DB pods" \
  "$(printf '%s\n%s\n' "$IP0" "$IP1" | sort | tr '\n' ' ')" "$EP_HL"
check "postgresql-hl does NOT include failover CronJob pods" \
  bash -c "! oc -n $NS get endpoints postgresql-hl -o jsonpath='{..targetRef.name}' 2>/dev/null | grep -q failover"

# Real DNS + routing from inside a pod
check_eq "connecting through postgresql-rw gives a primary" "f" \
  "$(pod_psql_host "$PRIMARY" postgresql-rw -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null)"
check_eq "connecting through postgresql-ro gives a standby" "t" \
  "$(pod_psql_host "$REPLICA" postgresql-ro -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null)"
check "connecting through postgresql-r works" \
  bash -c "oc -n $NS exec $PRIMARY -- env PGPASSWORD=$ADMIN_PASSWORD psql -h postgresql-r -U postgres -d postgres -tAc 'SELECT 1' 2>/dev/null | grep -qx 1"

# postgresql-r must balance across instances (per connection). Collect the
# backend address reported by the server over several fresh connections.
backend_ips() {
  local ip
  for _ in $(seq 1 20); do
    ip="$(pod_psql_host "$PRIMARY" postgresql-r -tAc 'SELECT inet_server_addr()' 2>/dev/null)"
    [ -n "$ip" ] && echo "$ip"
  done | sort -u
}
r_balances() { [ "$(backend_ips | wc -l)" -ge 2 ]; }
check "postgresql-r distributes connections across more than one instance" r_balances

# Per-pod DNS of the headless service
check_eq "headless per-pod DNS resolves and connects (primary)" "1" \
  "$(pod_psql_host "$REPLICA" "${PRIMARY}.postgresql-hl.${NS}.svc.cluster.local" -tAc 'SELECT 1' 2>/dev/null)"
check_eq "headless per-pod DNS resolves and connects (replica)" "1" \
  "$(pod_psql_host "$PRIMARY" "${REPLICA}.postgresql-hl.${NS}.svc.cluster.local" -tAc 'SELECT 1' 2>/dev/null)"

t_summary
