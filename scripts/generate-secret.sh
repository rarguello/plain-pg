#!/usr/bin/env bash
#
# generate-secret.sh -- crea/actualiza el Secret `postgres-credentials`.
#
# Las credenciales NUNCA se versionan: se generan aleatoriamente y se guardan
# en secrets/postgres-credentials.env (ignorado por git). Si ese archivo ya
# existe, se reutilizan las credenciales para no romper un despliegue en curso.
#
# Variables de entorno opcionales: NAMESPACE, POSTGRESQL_USER,
# POSTGRESQL_DATABASE, POSTGRESQL_MASTER_USER.
#
set -euo pipefail

NS="${NAMESPACE:-pg-ha-lab}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/secrets"
SECRET_FILE="$OUT_DIR/postgres-credentials.env"

POSTGRESQL_USER="${POSTGRESQL_USER:-app}"
POSTGRESQL_DATABASE="${POSTGRESQL_DATABASE:-appdb}"
POSTGRESQL_MASTER_USER="${POSTGRESQL_MASTER_USER:-replicator}"

# Password alfanumerico (evita problemas de comillas en primary_conninfo).
gen() { head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }

mkdir -p "$OUT_DIR"

if [ -f "$SECRET_FILE" ]; then
  echo "==> Reutilizando credenciales existentes en $SECRET_FILE"
  # shellcheck disable=SC1090
  source "$SECRET_FILE"
else
  echo "==> Generando credenciales nuevas en $SECRET_FILE"
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
  echo "==> El namespace $NS no existe todavia; se creara al aplicar los manifiestos." >&2
  echo "    (crealo con: oc apply -k manifests/overlays/lab)" >&2
  exit 1
fi

oc -n "$NS" create secret generic postgres-credentials \
  --from-literal=POSTGRESQL_USER="$POSTGRESQL_USER" \
  --from-literal=POSTGRESQL_PASSWORD="$POSTGRESQL_PASSWORD" \
  --from-literal=POSTGRESQL_DATABASE="$POSTGRESQL_DATABASE" \
  --from-literal=POSTGRESQL_ADMIN_PASSWORD="$POSTGRESQL_ADMIN_PASSWORD" \
  --from-literal=POSTGRESQL_MASTER_USER="$POSTGRESQL_MASTER_USER" \
  --from-literal=POSTGRESQL_MASTER_PASSWORD="$POSTGRESQL_MASTER_PASSWORD" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f - >/dev/null

echo "==> Secret postgres-credentials aplicado en $NS"
echo "    usuario app:  $POSTGRESQL_USER / db: $POSTGRESQL_DATABASE"
echo "    usuario repl: $POSTGRESQL_MASTER_USER"
