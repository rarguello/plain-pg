#!/usr/bin/env bash
# t18 -- Imagen: el digest fijado en el overlay coincide con el del registro y
#        con el que usan los pods.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

echo "### t18 imagen y digest"

PIN="$(grep -oE 'sha256:[0-9a-f]{64}' "$ROOT_DIR/manifests/overlays/lab/kustomization.yaml" | head -1)"
check "el overlay fija un digest" bash -c "[ -n '$PIN' ]"

RUNNING="$(oc -n "$NS" get sts postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"
check_contains "el StatefulSet usa el digest fijado" "$PIN" "$RUNNING"

# Nota: .status.image es la referencia fijada (digest del manifest-list, multi-arch);
# .status.imageID es el digest de la imagen de la plataforma (amd64), que es
# distinto. Por eso se compara la referencia, no el imageID.
POD_IMAGE="$(oc -n "$NS" get pod "$(primary_pod)" -o jsonpath='{.status.containerStatuses[0].image}')"
check_eq "el pod corre exactamente esa referencia" "$RUNNING" "$POD_IMAGE"
POD_IMAGEID="$(oc -n "$NS" get pod "$(primary_pod)" -o jsonpath='{.status.containerStatuses[0].imageID}')"
check_match "el imageID resuelve al mismo repositorio" \
  "^registry\.redhat\.io/rhel10/postgresql-18@sha256:[0-9a-f]{64}$" "$POD_IMAGEID"

AUTHFILE="${AUTHFILE:-$HOME/.pull-secret.json}"
if command -v skopeo >/dev/null 2>&1 && [ -f "$AUTHFILE" ]; then
  LIVE="$(skopeo inspect --authfile "$AUTHFILE" docker://registry.redhat.io/rhel10/postgresql-18:latest 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' | head -1)"
  check_eq "el digest fijado es el actual del registro" "$LIVE" "$PIN"
else
  c_skip "skopeo o el authfile no estan disponibles; no se compara con el registro"
fi

# La imagen es PostgreSQL 18 sobre UBI10
check_match "la imagen declara PLATFORM el10" "el10" \
  "$(oc -n "$NS" exec "$(primary_pod)" -- printenv PLATFORM 2>/dev/null)"
check_match "postgres es 18.x" "^postgres \(PostgreSQL\) 18\." \
  "$(oc -n "$NS" exec "$(primary_pod)" -- postgres --version 2>/dev/null)"

t_summary
