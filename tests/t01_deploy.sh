#!/usr/bin/env bash
# t01 -- Deployment: all objects exist and the pods are healthy.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

echo "### t01 deployment: objects, PVCs, pods, UBI image"

check "namespace $NS exists"                 oc get ns "$NS"
check "Secret postgresql-credentials exists"   oc -n "$NS" get secret postgresql-credentials
for k in POSTGRESQL_USER POSTGRESQL_PASSWORD POSTGRESQL_DATABASE \
         POSTGRESQL_ADMIN_PASSWORD POSTGRESQL_MASTER_USER POSTGRESQL_MASTER_PASSWORD; do
  check "the Secret has the key $k" \
    bash -c "[ -n \"\$(oc -n $NS get secret postgresql-credentials -o jsonpath='{.data.$k}')\" ]"
done

check "ConfigMap postgresql-scripts exists" oc -n "$NS" get cm postgresql-scripts
check "ConfigMap postgresql-role exists"    oc -n "$NS" get cm postgresql-role
check "Service postgresql-hl exists"        oc -n "$NS" get svc postgresql-hl
check "Service postgresql-rw exists"        oc -n "$NS" get svc postgresql-rw
check "Service postgresql-ro exists"        oc -n "$NS" get svc postgresql-ro
check "StatefulSet postgresql exists"       oc -n "$NS" get sts postgresql
check "NetworkPolicy postgresql-ingress exists" oc -n "$NS" get networkpolicy postgresql-ingress
check "CronJob postgresql-failover exists"  oc -n "$NS" get cronjob postgresql-failover

check_eq "replicas=2" "2" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}')"
check_eq "serviceName=postgresql-hl" "postgresql-hl" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.serviceName}')"
check_eq "podManagementPolicy=Parallel" "Parallel" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.podManagementPolicy}')"
check_eq "updateStrategy=OnDelete" "OnDelete" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.updateStrategy.type}')"

# Bound PVCs
for p in pgdata-postgresql-0 pgdata-postgresql-1; do
  check_eq "PVC $p is Bound" "Bound" \
    "$(oc -n "$NS" get pvc "$p" -o jsonpath='{.status.phase}' 2>/dev/null)"
done
check_eq "the PVCs use the default StorageClass" "${STORAGE_CLASS:-lvms-vg1}" \
  "$(oc -n "$NS" get pvc pgdata-postgresql-0 -o jsonpath='{.spec.storageClassName}' 2>/dev/null)"

# Ready pods
for p in postgresql-0 postgresql-1; do
  wait_for 120 "pod $p is Ready" pod_ready "$p"
done

# Image: UBI + PG18, pinned by digest
IMG="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
check_contains "the image comes from registry.redhat.io" "registry.redhat.io/rhel10/postgresql-18" "$IMG"
check_contains "the image is pinned by digest" "@sha256:" "$IMG"
VER="$(oc -n "$NS" exec postgresql-0 -- postgres --version 2>/dev/null)"
check_match "the server is PostgreSQL 18.x" "^postgres \(PostgreSQL\) 18\." "$VER"
OSREL="$(oc -n "$NS" exec postgresql-0 -- cat /etc/os-release 2>/dev/null)"
check_match "the base is Red Hat Enterprise Linux (UBI)" "Red Hat Enterprise Linux" "$OSREL"

t_summary
