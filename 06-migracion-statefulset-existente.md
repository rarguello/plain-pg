###############################################################################
# 06-migracion-statefulset-existente.md
# Procedimiento paso a paso para migrar del StatefulSet actual (1 réplica)
# al nuevo StatefulSet con replicación.
#
# ESCENARIOS DE MIGRACIÓN:
#
# A) El StatefulSet actual se llama IGUAL que el nuevo (pg-keycloak)
#    → Migración in-place: reemplazar el STS, el PVC se reutiliza.
#
# B) El StatefulSet actual tiene OTRO NOMBRE
#    → Opción 1: Adaptar los YAMLs al nombre existente (recomendado)
#    → Opción 2: Crear el nuevo STS, migrar datos con pg_dump/restore
#
# ESTE DOCUMENTO CUBRE EL ESCENARIO A (más común).
###############################################################################

# ============================================================================
# PASO 0: PREPARACIÓN
# ============================================================================

# Verificar el nombre y estado del StatefulSet actual
oc get statefulset -n produbanco-databases
oc get pvc -n produbanco-databases

# Anotar el nombre exacto del StatefulSet, el PVC y la imagen actual.
# Ejemplo de salida:
#   NAME           READY   AGE
#   pg-keycloak    1/1     90d
#
#   NAME                       STATUS   VOLUME     CAPACITY   ACCESS MODES
#   pgdata-pg-keycloak-0       Bound    pvc-xxx    20Gi       RWO

# Hacer un dump de la base de datos ANTES de cualquier cambio (safety net)
oc exec pg-keycloak-0 -n produbanco-databases -- \
  pg_dumpall -U postgres > /tmp/keycloak-db-backup-$(date +%Y%m%d).sql

# ============================================================================
# PASO 1: APLICAR RECURSOS NUEVOS (sin impacto aún)
# ============================================================================

# Estos recursos no afectan al StatefulSet existente.
oc apply -f 01-replication-secret.yaml
oc apply -f 02-configmap-scripts.yaml
oc apply -f 03-headless-service.yaml
oc apply -f 04-services-rw-ro.yaml

# Verificar que se crearon:
oc get secret pg-replication-credentials -n produbanco-databases
oc get configmap pg-ha-scripts -n produbanco-databases
oc get svc -n produbanco-databases | grep pg-keycloak

# ============================================================================
# PASO 2: PREPARAR EL POSTGRESQL EXISTENTE PARA REPLICACIÓN
# ============================================================================

# ANTES de reemplazar el StatefulSet, necesitamos configurar el PostgreSQL
# existente para que acepte conexiones de replicación.
# Esto se hace CON EL POD ACTUAL CORRIENDO (sin downtime).

# 2a. Crear el usuario de replicación
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'CAMBIAR_ESTE_PASSWORD_REPLICACION';"

# 2b. Crear el replication slot
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "SELECT pg_create_physical_replication_slot('replica_1_slot');"

# 2c. Configurar wal_level (requiere restart de PostgreSQL)
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "ALTER SYSTEM SET wal_level = 'replica';"

oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "ALTER SYSTEM SET max_wal_senders = 5;"

oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "ALTER SYSTEM SET max_replication_slots = 5;"

oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "ALTER SYSTEM SET wal_keep_size = '512MB';"

oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "ALTER SYSTEM SET hot_standby = on;"

# 2d. Agregar entrada de replicación a pg_hba.conf
# NOTA: La ruta de pg_hba.conf depende de la imagen.
# Para RHEL9: /var/lib/pgsql/data/userdata/pg_hba.conf
oc exec pg-keycloak-0 -n produbanco-databases -- bash -c '
  echo "host replication replicator 10.0.0.0/8 scram-sha-256" >> /var/lib/pgsql/data/userdata/pg_hba.conf
  echo "host replication replicator 172.16.0.0/12 scram-sha-256" >> /var/lib/pgsql/data/userdata/pg_hba.conf
'

# 2e. Verificar que wal_level necesita restart
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "SELECT name, setting, pending_restart FROM pg_settings WHERE name = 'wal_level';"

# Si pending_restart = true, necesitamos reiniciar PostgreSQL.
# Esto causa un downtime breve (segundos).

# ============================================================================
# PASO 3: REEMPLAZAR EL STATEFULSET
# ============================================================================

# 3a. Escalar a 0 (apaga el pod, libera el PVC sin eliminarlo)
oc scale statefulset pg-keycloak --replicas=0 -n produbanco-databases

# Esperar a que el pod termine
oc wait --for=delete pod/pg-keycloak-0 -n produbanco-databases --timeout=120s

# 3b. Verificar que el PVC sigue existiendo
oc get pvc pgdata-pg-keycloak-0 -n produbanco-databases
# STATUS debe ser "Bound"

# 3c. Eliminar el StatefulSet VIEJO (sin cascade, preserva PVCs)
oc delete statefulset pg-keycloak -n produbanco-databases --cascade=orphan

# 3d. Aplicar el StatefulSet NUEVO
oc apply -f 05-statefulset-keycloak.yaml

# ============================================================================
# PASO 4: VERIFICAR
# ============================================================================

# 4a. Esperar a que pod-0 arranque (usa el PVC existente con los datos)
oc wait --for=condition=Ready pod/pg-keycloak-0 \
  -n produbanco-databases --timeout=300s

# 4b. Verificar que pod-0 arrancó como primary
oc logs pg-keycloak-0 -n produbanco-databases | head -20
# Debería mostrar: "Rol detectado: PRIMARY"
# y: "Directorio de datos existente..."

# 4c. Verificar que PostgreSQL está funcionando
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"
# Esperado: f (false = es primary)

# 4d. Esperar a que pod-1 arranque (hace pg_basebackup)
oc wait --for=condition=Ready pod/pg-keycloak-1 \
  -n produbanco-databases --timeout=600s

# NOTA: pod-1 puede tomar varios minutos dependiendo del tamaño de la BD.
# Monitorear el progreso:
oc logs -f pg-keycloak-1 -n produbanco-databases

# 4e. Verificar replicación desde el primary
oc exec pg-keycloak-0 -n produbanco-databases -- \
  /scripts/check-replication.sh

# Esperado:
#   application_name | state     | sync_state | replay_lag_bytes
#   pg-keycloak-1    | streaming | async      | 0

# 4f. Verificar que la réplica sirve lecturas
oc exec pg-keycloak-1 -n produbanco-databases -- \
  psql -U postgres -d keycloak -c "SELECT pg_is_in_recovery();"
# Esperado: t (true = es réplica)

oc exec pg-keycloak-1 -n produbanco-databases -- \
  psql -U postgres -d keycloak -c "SELECT count(*) FROM information_schema.tables;"
# Debería retornar el mismo count que en pod-0

# 4g. Verificar el Service -rw (debe apuntar solo a pod-0)
oc get endpoints pg-keycloak-rw -n produbanco-databases
# Debe mostrar solo la IP de pod-0

# ============================================================================
# PASO 5: RECONECTAR KEYCLOAK
# ============================================================================

# Si Keycloak apuntaba al service anterior, actualizar la URL de conexión
# para que apunte al nuevo service -rw:
#
# jdbc:postgresql://pg-keycloak-rw.produbanco-databases.svc:5432/keycloak
#
# Si el Service anterior tenía el mismo nombre y selectores, Keycloak
# debería reconectarse automáticamente sin cambios.

# ============================================================================
# ¡LISTO! El StatefulSet ahora tiene replicación streaming.
# ============================================================================
