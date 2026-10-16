#!/usr/bin/env bash
#
# update-digest.sh -- prints the current image digest and (with --apply)
# replaces it in the base (the one place the image is pinned; every overlay
# inherits it). Changing the platform or the PostgreSQL version is a manual edit
# of that same block: see docs/image-matrix.md.
#
# Usage:
#   ./scripts/update-digest.sh            # only shows the digest
#   ./scripts/update-digest.sh --apply    # updates manifests/base/kustomization.yaml
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT_DIR/manifests/components/image/kustomization.yaml"
IMG="${IMG:-$(grep -oE 'newName: registry\.redhat\.io/[a-z0-9./-]+' "$PIN" | sed 's/newName: //')}"
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

F="$ROOT_DIR/manifests/components/image/kustomization.yaml"
sed -i -E "s#(digest: )sha256:[0-9a-f]{64}#\1${DIGEST}#" "$F"
echo "Updated: $F"
