#!/usr/bin/env bash
# t04 -- Services y DNS: -rw/-ro/-hl apuntan a los pods correctos.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t04 services y DNS"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
IP0="$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.status.podIP}')"
IP1="$(oc -n "$NS" get pod "$REPLICA" -o jsonpath='{.status.podIP}')"

EP_RW="$(oc -n "$NS" get endpoints postgres-rw -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
EP_RO="$(oc -n "$NS" get endpoints postgres-ro -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
EP_HL="$(oc -n "$NS" get endpoints postgres-hl -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"

check_eq "postgres-rw apunta solo al primary" "$IP0" "$EP_RW"
check_eq "postgres-ro apunta solo a la replica" "$IP1" "$EP_RO"
check_eq "postgres-hl tiene exactamente los 2 pods de la BD" \
  "$(printf '%s\n%s\n' "$IP0" "$IP1" | sort | tr '\n' ' ')" "$EP_HL"
check "postgres-hl NO incluye pods del CronJob de failover" \
  bash -c "! oc -n $NS get endpoints postgres-hl -o jsonpath='{..targetRef.name}' 2>/dev/null | grep -q failover"

# DNS + enrutamiento reales desde dentro de un pod
check_eq "conectar por postgres-rw devuelve un primary" "f" \
  "$(pod_psql_host "$PRIMARY" postgres-rw -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null)"
check_eq "conectar por postgres-ro devuelve un standby" "t" \
  "$(pod_psql_host "$REPLICA" postgres-ro -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null)"

# DNS por-pod del headless service
check_eq "DNS por-pod del headless resuelve y conecta (primary)" "1" \
  "$(pod_psql_host "$REPLICA" "${PRIMARY}.postgres-hl.${NS}.svc.cluster.local" -tAc 'SELECT 1' 2>/dev/null)"
check_eq "DNS por-pod del headless resuelve y conecta (replica)" "1" \
  "$(pod_psql_host "$PRIMARY" "${REPLICA}.postgres-hl.${NS}.svc.cluster.local" -tAc 'SELECT 1' 2>/dev/null)"

t_summary
