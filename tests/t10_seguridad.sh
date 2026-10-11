#!/usr/bin/env bash
# t10 -- Seguridad y limpieza: non-root, SCC, RBAC minimo, sin secretos en git.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t10 seguridad y limpieza"

PRIMARY="$(primary_pod)"

# Non-root
check_ne "el contenedor NO corre como root" "0" \
  "$(oc -n "$NS" exec "$PRIMARY" -- id -u 2>/dev/null)"

# PodSecurity restricted
SC="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.containers[0].securityContext}')"
check_contains "allowPrivilegeEscalation=false" '"allowPrivilegeEscalation":false' "$SC"
check_contains "se dropean TODAS las capabilities" '"drop":["ALL"]' "$SC"
PSC="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.securityContext}')"
check_contains "seccompProfile RuntimeDefault" '"type":"RuntimeDefault"' "$PSC"
check_contains "runAsNonRoot=true" '"runAsNonRoot":true' "$PSC"

check_match "el pod recibio un SCC restricted" "restricted" \
  "$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.metadata.annotations.openshift\.io/scc}' 2>/dev/null)"
check_eq "el namespace exige PodSecurity restricted" "restricted" \
  "$(oc get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)"

# RBAC minimo del controlador de failover
VERBS="$(oc -n "$NS" get role postgres-failover -o jsonpath='{.rules[*].verbs}' 2>/dev/null)"
check_contains "el Role del failover permite borrar pods" "delete" "$VERBS"
check "el Role NO permite crear pods" bash -c "! echo '$VERBS' | grep -qw create"
check "el Role NO es ClusterRole" bash -c "! oc get clusterrole postgres-failover >/dev/null 2>&1"

# Los pods del CronJob no deben colisionar con los selectores de los Services
CJ_LABELS="$(oc -n "$NS" get cronjob postgres-failover -o jsonpath='{.spec.jobTemplate.spec.template.metadata.labels}')"
check "las labels del CronJob NO incluyen name=postgresql" \
  bash -c "! echo '$CJ_LABELS' | grep -q 'postgresql'"

# Secretos fuera de git
check "no se versiona nada dentro de secrets/" \
  bash -c "! git -C '$ROOT_DIR' ls-files | grep -q '^secrets/'"
check "el password real NO esta versionado en git" \
  bash -c "! git -C '$ROOT_DIR' grep -qF '$APP_PASSWORD'"
check "el directorio secrets/ esta en .gitignore" \
  bash -c "git -C '$ROOT_DIR' check-ignore secrets/postgres-credentials.env >/dev/null"

# La imagen es UBI de Red Hat
IMG="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"
check_contains "la imagen es UBI (registry.redhat.io)" "registry.redhat.io" "$IMG"
check "no se usa la imagen docker.io/library/postgres" \
  bash -c "! git -C '$ROOT_DIR' grep -q 'docker.io/library/postgres' -- manifests/"

t_summary
