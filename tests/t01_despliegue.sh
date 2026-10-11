#!/usr/bin/env bash
# t01 -- Despliegue: existen todos los objetos y los pods estan sanos.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

echo "### t01 despliegue: objetos, PVCs, pods, imagen UBI"

check "existe el namespace $NS"                 oc get ns "$NS"
check "existe el Secret postgres-credentials"   oc -n "$NS" get secret postgres-credentials
for k in POSTGRESQL_USER POSTGRESQL_PASSWORD POSTGRESQL_DATABASE \
         POSTGRESQL_ADMIN_PASSWORD POSTGRESQL_MASTER_USER POSTGRESQL_MASTER_PASSWORD; do
  check "el Secret tiene la clave $k" \
    bash -c "[ -n \"\$(oc -n $NS get secret postgres-credentials -o jsonpath='{.data.$k}')\" ]"
done

check "existe ConfigMap postgres-scripts" oc -n "$NS" get cm postgres-scripts
check "existe ConfigMap postgres-role"    oc -n "$NS" get cm postgres-role
check "existe Service postgres-hl"        oc -n "$NS" get svc postgres-hl
check "existe Service postgres-rw"        oc -n "$NS" get svc postgres-rw
check "existe Service postgres-ro"        oc -n "$NS" get svc postgres-ro
check "existe StatefulSet postgres"       oc -n "$NS" get sts postgres
check "existe NetworkPolicy postgres-ingress" oc -n "$NS" get networkpolicy postgres-ingress
check "existe CronJob postgres-failover"  oc -n "$NS" get cronjob postgres-failover

check_eq "replicas=2" "2" \
  "$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.replicas}')"
check_eq "serviceName=postgres-hl" "postgres-hl" \
  "$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.serviceName}')"
check_eq "podManagementPolicy=Parallel" "Parallel" \
  "$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.podManagementPolicy}')"
check_eq "updateStrategy=OnDelete" "OnDelete" \
  "$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.updateStrategy.type}')"

# PVCs ligados
for p in pgdata-postgres-0 pgdata-postgres-1; do
  check_eq "PVC $p esta Bound" "Bound" \
    "$(oc -n "$NS" get pvc "$p" -o jsonpath='{.status.phase}' 2>/dev/null)"
done
check_eq "los PVC usan la StorageClass por defecto" "lvms-vg1" \
  "$(oc -n "$NS" get pvc pgdata-postgres-0 -o jsonpath='{.spec.storageClassName}' 2>/dev/null)"

# Pods listos
for p in postgres-0 postgres-1; do
  wait_for 120 "pod $p esta Ready" pod_ready "$p"
done

# Imagen: UBI + PG18, fijada por digest
IMG="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"
check_contains "la imagen viene de registry.redhat.io" "registry.redhat.io/rhel10/postgresql-18" "$IMG"
check_contains "la imagen esta fijada por digest" "@sha256:" "$IMG"
VER="$(oc -n "$NS" exec postgres-0 -- postgres --version 2>/dev/null)"
check_match "el servidor es PostgreSQL 18.x" "^postgres \(PostgreSQL\) 18\." "$VER"
OSREL="$(oc -n "$NS" exec postgres-0 -- cat /etc/os-release 2>/dev/null)"
check_match "la base es Red Hat Enterprise Linux (UBI)" "Red Hat Enterprise Linux" "$OSREL"

t_summary
