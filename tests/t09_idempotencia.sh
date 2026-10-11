#!/usr/bin/env bash
# t09 -- Idempotencia: aplicar dos veces no cambia nada.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

echo "### t09 idempotencia"

OVERLAY="$ROOT_DIR/manifests/overlays/lab"

# resourceVersion de los objetos clave: es la senal real de idempotencia.
# (No se usa la palabra "configured/unchanged" de `oc apply`: para
#  StatefulSet con volumeClaimTemplates, kubectl/oc siempre imprime
#  "configured" aunque no cambie nada. Ver docs/99-notas-tecnicas.md.)
key_rvs() {
  local r
  for r in sts/postgres svc/postgres-hl svc/postgres-rw svc/postgres-ro \
           cm/postgres-scripts cm/postgres-role cronjob/postgres-failover \
           networkpolicy/postgres-ingress; do
    oc -n "$NS" get "$r" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null; echo
  done
}

# Sincroniza el estado con el repo antes de medir.
oc apply -k "$OVERLAY" >/dev/null 2>&1
BEFORE="$(key_rvs)"
oc apply -k "$OVERLAY" >/dev/null 2>&1
AFTER="$(key_rvs)"
check_eq "un segundo apply no modifica ningun objeto (resourceVersion estable)" "$BEFORE" "$AFTER"

# El render de kustomize es determinista
A="$(oc kustomize "$OVERLAY" 2>/dev/null | sha256sum)"
B="$(oc kustomize "$OVERLAY" 2>/dev/null | sha256sum)"
check_eq "kustomize produce el mismo render siempre" "$A" "$B"

# deploy.sh es idempotente (no falla al re-ejecutarse)
check "deploy.sh se re-ejecuta sin error" \
  env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh"

# La imagen sigue fijada por digest (no se rompe el pinning)
IMG="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"
check_contains "la imagen sigue fijada por digest" "@sha256:" "$IMG"

t_summary
