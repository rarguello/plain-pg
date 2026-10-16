#!/usr/bin/env bash
#
# test-image.sh -- runs the whole suite against another Red Hat PostgreSQL image
# and leaves the transcript in docs/evidence/. It pins that image temporarily and
# restores the pin at the end, so the run is comparable with the default one.
#
# Usage:
#   ./scripts/test-image.sh rhel9/postgresql-16 [tag]
#
# Destructive: it wipes the PGDATA PVCs (another image means another data
# directory) and runs the full suite, which includes failover and teardown.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

REPO="${1:?usage: test-image.sh <repo> [tag]}"
TAG="${2:-latest}"
AUTHFILE="${AUTHFILE:-$HOME/.pull-secret.json}"
PIN_FILE="$ROOT_DIR/manifests/components/image/kustomization.yaml"

PG="${REPO##*postgresql-}"
PLATFORM="el${REPO#rhel}"; PLATFORM="${PLATFORM%%/*}"
OUT="$ROOT_DIR/docs/evidence/$(date +%F)-${REPO//\//-}-full-suite.txt"

restore() { git -C "$ROOT_DIR" checkout -- "manifests/components/image/kustomization.yaml" 2>/dev/null || true; }
trap restore EXIT

echo "==> $REPO:$TAG  (PostgreSQL $PG, $PLATFORM)"
DIGEST="$(skopeo inspect --authfile "$AUTHFILE" "docker://registry.redhat.io/$REPO:$TAG" | jq -r '.Digest')"
echo "==> digest $DIGEST"

echo "==> pinning it temporarily"
python3 - "$PIN_FILE" "$REPO" "$DIGEST" <<'PY'
import re, sys
path, repo, digest = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
s = re.sub(r'name: registry\.redhat\.io/\S+', 'name: registry.redhat.io/' + repo, s)
s = re.sub(r'digest: sha256:[0-9a-f]{64}', 'digest: ' + digest, s)
open(path, 'w').write(s)
PY

echo "==> wiping the data"
oc -n "$NS" delete statefulset postgresql --wait=true >/dev/null 2>&1 || true
oc -n "$NS" delete pvc pgdata-postgresql-0 pgdata-postgresql-1 --wait=true >/dev/null 2>&1 || true

echo "==> running the suite (transcript: ${OUT#"$ROOT_DIR"/})"
set +e
EXPECT_PLATFORM="$PLATFORM" EXPECT_PG="$PG" "$ROOT_DIR/tests/run-all.sh" > "$OUT" 2>&1
RC=$?
set -e

echo "==> restoring the pin"
restore
tail -24 "$OUT"
echo "==> exit=$RC"
exit "$RC"
