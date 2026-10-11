###############################################################################
# 07-operaciones-dia-a-dia.md
# Guía rápida de operaciones para el equipo de Produbanco.
# Imprimir y tener a mano.
###############################################################################

# ============================================================================
# VERIFICACIONES RUTINARIAS (ejecutar periódicamente o ante incidentes)
# ============================================================================

# --- ¿Están corriendo los dos pods? ---
oc get pods -l app.kubernetes.io/instance=pg-keycloak -n produbanco-databases
# ESPERADO: 2/2 pods en Running

# --- ¿Está replicando? ---
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "SELECT application_name, state, \
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag \
  FROM pg_stat_replication;"
# ESPERADO: pg-keycloak-1 | streaming | 0 bytes (o pocos KB)

# --- ¿Cuánto espacio queda? ---
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "SELECT pg_size_pretty(pg_database_size('keycloak')) AS db_size;"

oc exec pg-keycloak-0 -n produbanco-databases -- df -h /var/lib/pgsql/data


# ============================================================================
# ESCENARIO: POD-0 (PRIMARY) SE CAE
# ============================================================================
#
# ¿Qué pasa automáticamente?
#   1. Kubernetes detecta que el pod murió
#   2. Si el nodo está sano: reprograma pod-0 inmediatamente (~30s)
#   3. Si el nodo falló: espera el timeout (5 min), luego reprograma
#   4. Pod-0 arranca, engancha su PVC, PostgreSQL hace WAL replay
#   5. Pod-1 (réplica) se reconecta automáticamente al primary
#
# ¿Qué pasa con Keycloak durante la caída?
#   - Keycloak pierde conexión a la BD y los logins fallan
#   - Cuando pod-0 vuelve, Keycloak reconecta automáticamente
#   - Downtime típico: 1-10 minutos dependiendo del escenario
#
# ¿Debo hacer algo?
#   - NO. Esperar a que Kubernetes reprograme pod-0.
#   - Solo intervenir si después de 15 minutos pod-0 no vuelve.


# ============================================================================
# ESCENARIO: POD-1 (RÉPLICA) SE CAE
# ============================================================================
#
# ¿Qué pasa?
#   - NADA para Keycloak. El primary sigue funcionando normalmente.
#   - Kubernetes reprograma pod-1 automáticamente.
#   - Al arrancar, pod-1 se reconecta al primary y sincroniza los WALs
#     que se perdió durante la caída.
#
# ¿Debo hacer algo?
#   - NO. Solo verificar después que la replicación se restableció:
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"


# ============================================================================
# ESCENARIO: EL PVC DE POD-0 SE CORROMPE (caso extremo)
# ============================================================================
#
# Esto es raro con Ceph/ODF pero puede pasar. La réplica tiene los datos.
#
# PROCEDIMIENTO:

# 1. Escalar a 0
oc scale statefulset pg-keycloak --replicas=0 -n produbanco-databases

# 2. Conectarse a pod-1 ANTES de que se apague y promover
#    (si pod-1 ya se apagó, hay que hacer un procedimiento diferente)
#    NOTA: Si ya se escaló a 0, pod-1 también se apaga. En ese caso,
#    primero eliminar el PVC roto, luego escalar a 1 para que pod-0
#    se cree nuevo y copie desde la réplica... pero no hay réplica.
#
#    MEJOR PROCEDIMIENTO:
#    a. NO escalar a 0 si pod-1 sigue vivo
#    b. Promover pod-1 primero:
oc exec pg-keycloak-1 -n produbanco-databases -- \
  pg_ctl promote -D /var/lib/pgsql/data/userdata
#    c. Ahora pod-1 es un primary independiente
#    d. Apuntar Keycloak temporalmente a pg-keycloak-1 directamente:
#       jdbc:postgresql://pg-keycloak-1.pg-keycloak-headless.produbanco-databases.svc:5432/keycloak
#    e. Eliminar el PVC corrupto de pod-0:
oc delete pvc pgdata-pg-keycloak-0 -n produbanco-databases
#    f. Eliminar pod-0 para que se recree:
oc delete pod pg-keycloak-0 -n produbanco-databases
#    g. Pod-0 arrancará con PVC vacío, pero el script detecta ordinal=0
#       e inicializa como primary nuevo. Esto NO es lo que queremos
#       porque los datos están en pod-1.
#
#    SOLUCIÓN PRÁCTICA: restaurar desde backup de Velero/OADP
#    y reconstruir ambos pods. Este es el caso donde Velero es esencial.


# ============================================================================
# ESCENARIO: NECESITO HACER MANTENIMIENTO EN UN NODO
# ============================================================================

# Si el nodo tiene pod-0 (primary):
#   1. Kubernetes hará drain del nodo → pod-0 se mueve a otro nodo
#   2. El PVC (Ceph RBD) se reattach en el nuevo nodo
#   3. Downtime: 1-5 minutos mientras se mueve
#
# Si el nodo tiene pod-1 (réplica):
#   1. Drain del nodo → pod-1 se mueve
#   2. Zero downtime para Keycloak (solo lectura del primary no se afecta)

# Para drenar un nodo específico:
# oc adm drain <nombre-nodo> --ignore-daemonsets --delete-emptydir-data


# ============================================================================
# OPERACIÓN: REINICIAR POSTGRESQL (sin perder datos)
# ============================================================================

# Reiniciar solo la réplica (zero downtime):
oc delete pod pg-keycloak-1 -n produbanco-databases
# Kubernetes lo recrea automáticamente. Se reconecta al primary.

# Reiniciar el primary (downtime breve):
oc delete pod pg-keycloak-0 -n produbanco-databases
# Kubernetes lo recrea. Keycloak pierde conexión ~30s-2min.
# La réplica detecta que el primary cayó y espera a que vuelva.


# ============================================================================
# OPERACIÓN: ESCALAR RÉPLICAS
# ============================================================================

# Agregar una segunda réplica (de 2 a 3 pods):
oc scale statefulset pg-keycloak --replicas=3 -n produbanco-databases
# NOTA: Primero crear el replication slot en el primary:
oc exec pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -c "SELECT pg_create_physical_replication_slot('replica_2_slot');"

# Reducir (de 3 a 2 pods):
oc scale statefulset pg-keycloak --replicas=2 -n produbanco-databases
# El PVC de pod-2 queda huérfano. Eliminarlo manualmente si no se necesita:
oc delete pvc pgdata-pg-keycloak-2 -n produbanco-databases


# ============================================================================
# OPERACIÓN: VER LOGS DE POSTGRESQL
# ============================================================================

# Logs del primary:
oc logs pg-keycloak-0 -n produbanco-databases

# Logs de la réplica:
oc logs pg-keycloak-1 -n produbanco-databases

# Seguir logs en tiempo real:
oc logs -f pg-keycloak-0 -n produbanco-databases

# Buscar errores:
oc logs pg-keycloak-0 -n produbanco-databases | grep -i error


# ============================================================================
# CONEXIÓN DIRECTA A POSTGRESQL (para troubleshooting)
# ============================================================================

# Conectar al primary como superusuario:
oc exec -it pg-keycloak-0 -n produbanco-databases -- \
  psql -U postgres -d keycloak

# Conectar a la réplica (solo lectura):
oc exec -it pg-keycloak-1 -n produbanco-databases -- \
  psql -U postgres -d keycloak

# Desde un pod temporal (si los pods de PG no están disponibles):
oc run -it --rm pg-debug \
  --namespace=produbanco-databases \
  --image=registry.redhat.io/rhel9/postgresql-16 \
  -- psql -h pg-keycloak-rw -U postgres -d keycloak
