#!/usr/bin/env bash
# t19 -- Regresion: los pods auxiliares (backup, failover) NO deben colisionar
#        con los selectores de los Services de PostgreSQL.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

echo "### t19 selectores y labels (regresion)"

# Ninguna label de los pods auxiliares debe matchear los selectores de la BD
for cj in postgres-failover postgres-backup; do
  L="$(oc -n "$NS" get cronjob "$cj" -o jsonpath='{.spec.jobTemplate.spec.template.metadata.labels}' 2>/dev/null)"
  check "las labels del CronJob $cj no dicen name=postgresql" \
    bash -c "! echo '$L' | grep -q '\"app.kubernetes.io/name\":\"postgresql\"'"
  check "las labels del CronJob $cj no dicen instance=postgres" \
    bash -c "! echo '$L' | grep -q '\"app.kubernetes.io/instance\":\"postgres\"'"
done

# postgres-hl solo debe tener los pods de la BD
HL="$(oc -n "$NS" get endpoints postgres-hl -o jsonpath='{range .subsets[*].addresses[*]}{.targetRef.name}{"\n"}{end}' 2>/dev/null | sort | tr '\n' ' ')"
DB="$(db_pods | tr '\n' ' ')"
check_eq "postgres-hl contiene exactamente los pods de la BD" "$DB" "$HL"

# -rw y -ro seleccionan por nombre de pod (no por rol dinamico)
check_eq "postgres-rw selecciona por pod-name" "postgres-0" \
  "$(oc -n "$NS" get svc postgres-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"
check_eq "postgres-ro selecciona por pod-name" "postgres-1" \
  "$(oc -n "$NS" get svc postgres-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"

# El headless service publica direcciones de pods no listos (necesario para el arranque)
check_eq "postgres-hl publica pods no listos" "true" \
  "$(oc -n "$NS" get svc postgres-hl -o jsonpath='{.spec.publishNotReadyAddresses}' 2>/dev/null)"

t_summary
