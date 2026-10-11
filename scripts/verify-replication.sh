#!/usr/bin/env bash
#
# verify-replication.sh -- verifica el estado de la replicacion end-to-end.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_credentials

PRIMARY="$(primary_pod)"
mapfile -t REPLICAS < <(replica_pods)

echo "==========================================================================="
echo " Pods"
echo "==========================================================================="
oc -n "$NS" get pods -l app.kubernetes.io/instance=postgres -o wide

echo
echo "==========================================================================="
echo " Rol del primary declarado: $PRIMARY"
echo "==========================================================================="
IR="$(pod_in_recovery "$PRIMARY")"
echo "pg_is_in_recovery() = $IR   (esperado: f)"
[ "$IR" = "f" ] || { echo "FALLO: $PRIMARY no es primary"; exit 1; }

echo
echo "==========================================================================="
echo " Estado de replicacion en el primary (pg_stat_replication)"
echo "==========================================================================="
pod_psql_admin "$PRIMARY" -P pager=off -c "
  SELECT application_name,
         state,
         sync_state,
         pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))  AS sent_lag,
         pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag
  FROM pg_stat_replication;"

for r in "${REPLICAS[@]}"; do
  echo
  echo "==========================================================================="
  echo " Rol de la replica: $r"
  echo "==========================================================================="
  IR="$(pod_in_recovery "$r")"
  echo "pg_is_in_recovery() = $IR   (esperado: t)"
  [ "$IR" = "t" ] || { echo "FALLO: $r no es standby"; exit 1; }
done

echo
echo "==========================================================================="
echo " Prueba end-to-end: escribo en el primary y leo en la(s) replica(s)"
echo "==========================================================================="
pod_psql "$PRIMARY" -q -c "
  CREATE TABLE IF NOT EXISTS pg_ha_check(
    id bigserial PRIMARY KEY,
    ts timestamptz DEFAULT now(),
    nota text
  );"
pod_psql "$PRIMARY" -q -c "
  INSERT INTO pg_ha_check(nota) VALUES ('check-' || extract(epoch from now())::bigint);"
sleep 2

for r in "${REPLICAS[@]}"; do
  echo "-- lo que ve $r:"
  pod_psql "$r" -P pager=off -c "SELECT count(*) AS filas, max(ts) AS ultima FROM pg_ha_check;"
done

echo
echo "OK: replicacion verificada."
