#!/usr/bin/env bash
#
# generate-secret.sh -- creates/updates the Secret `postgresql-credentials`.
#
# Credentials are NEVER versioned: they are generated randomly and stored in
# secrets/postgresql-credentials.env (git-ignored). If that file already exists,
# the credentials are reused so as not to break a deployment in progress.
#
# Optional environment variables: NAMESPACE, POSTGRESQL_USER,
# POSTGRESQL_DATABASE, POSTGRESQL_MASTER_USER.
#
set -euo pipefail

NS="${NAMESPACE:-plain-pg}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/secrets"
SECRET_FILE="$OUT_DIR/postgresql-credentials.env"

POSTGRESQL_USER="${POSTGRESQL_USER:-app}"
POSTGRESQL_DATABASE="${POSTGRESQL_DATABASE:-appdb}"
POSTGRESQL_MASTER_USER="${POSTGRESQL_MASTER_USER:-replicator}"

# Alphanumeric password (avoids quoting problems in primary_conninfo).
gen() { head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }

# Never overwrite an existing Secret: the credentials are an input, not an
# artifact of this script. Rotating them here would leave PostgreSQL's roles
# unchanged and break new pods, replication, backups and failover.
if oc -n "$NS" get secret postgresql-credentials >/dev/null 2>&1; then
  echo "==> Secret postgresql-credentials already exists in $NS; leaving it as is."
  echo "    (delete it by hand first if you really want to rotate the credentials)"
  exit 0
fi

mkdir -p "$OUT_DIR"

if [ -f "$SECRET_FILE" ]; then
  echo "==> Reusing existing credentials in $SECRET_FILE"
  # shellcheck disable=SC1090
  source "$SECRET_FILE"
else
  echo "==> Generating new credentials in $SECRET_FILE"
  POSTGRESQL_PASSWORD="$(gen 24)"
  POSTGRESQL_ADMIN_PASSWORD="$(gen 24)"
  POSTGRESQL_MASTER_PASSWORD="$(gen 24)"
  umask 077
  cat > "$SECRET_FILE" <<EOF
POSTGRESQL_PASSWORD='$POSTGRESQL_PASSWORD'
POSTGRESQL_ADMIN_PASSWORD='$POSTGRESQL_ADMIN_PASSWORD'
POSTGRESQL_MASTER_PASSWORD='$POSTGRESQL_MASTER_PASSWORD'
EOF
fi

if ! oc get namespace "$NS" >/dev/null 2>&1; then
  echo "==> Namespace $NS does not exist yet; it will be created when the manifests are applied." >&2
  echo "    (create it with: oc apply -k manifests/overlays/lab)" >&2
  exit 1
fi

oc -n "$NS" create secret generic postgresql-credentials \
  --from-literal=POSTGRESQL_USER="$POSTGRESQL_USER" \
  --from-literal=POSTGRESQL_PASSWORD="$POSTGRESQL_PASSWORD" \
  --from-literal=POSTGRESQL_DATABASE="$POSTGRESQL_DATABASE" \
  --from-literal=POSTGRESQL_ADMIN_PASSWORD="$POSTGRESQL_ADMIN_PASSWORD" \
  --from-literal=POSTGRESQL_MASTER_USER="$POSTGRESQL_MASTER_USER" \
  --from-literal=POSTGRESQL_MASTER_PASSWORD="$POSTGRESQL_MASTER_PASSWORD" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f - >/dev/null

echo "==> Secret postgresql-credentials applied in $NS"
echo "    app user:  $POSTGRESQL_USER / db: $POSTGRESQL_DATABASE"
echo "    repl user: $POSTGRESQL_MASTER_USER"
