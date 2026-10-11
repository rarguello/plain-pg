#!/usr/bin/env bash
#
# actualizar-digest.sh -- imprime el digest actual de la imagen y (con --apply)
# lo reemplaza en los overlays.
#
# Uso:
#   ./scripts/actualizar-digest.sh            # solo muestra el digest
#   ./scripts/actualizar-digest.sh --apply    # actualiza los kustomization.yaml
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-registry.redhat.io/rhel10/postgresql-18}"
AUTHFILE="${AUTHFILE:-$HOME/.pull-secret.json}"

if ! command -v skopeo >/dev/null 2>&1; then
  echo "ERROR: se necesita 'skopeo'." >&2
  exit 1
fi

DIGEST="$(skopeo inspect --authfile "$AUTHFILE" "docker://$IMG:latest" | jq -r '.Digest')"
echo "Imagen: $IMG:latest"
echo "Digest: $DIGEST"

if [ "${1:-}" != "--apply" ]; then
  exit 0
fi

for f in "$ROOT_DIR"/manifests/overlays/*/kustomization.yaml; do
  sed -i -E "s#(digest: )sha256:[0-9a-f]{64}#\1${DIGEST}#" "$f"
  echo "Actualizado: $f"
done
