#!/usr/bin/env bash
#
# update-digest.sh -- prints the current image digest and (with --apply)
# replaces it in the overlays.
#
# Usage:
#   ./scripts/update-digest.sh            # only shows the digest
#   ./scripts/update-digest.sh --apply    # updates the kustomization.yaml
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-registry.redhat.io/rhel10/postgresql-18}"
AUTHFILE="${AUTHFILE:-$HOME/.pull-secret.json}"

if ! command -v skopeo >/dev/null 2>&1; then
  echo "ERROR: 'skopeo' is needed." >&2
  exit 1
fi

DIGEST="$(skopeo inspect --authfile "$AUTHFILE" "docker://$IMG:latest" | jq -r '.Digest')"
echo "Image: $IMG:latest"
echo "Digest: $DIGEST"

if [ "${1:-}" != "--apply" ]; then
  exit 0
fi

for f in "$ROOT_DIR"/manifests/overlays/*/kustomization.yaml; do
  sed -i -E "s#(digest: )sha256:[0-9a-f]{64}#\1${DIGEST}#" "$f"
  echo "Updated: $f"
done
