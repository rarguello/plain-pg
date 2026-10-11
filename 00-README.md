# PostgreSQL Streaming Replication sobre StatefulSet en OpenShift

## Enfoque

Agregar replicación a los StatefulSets existentes de PostgreSQL **sin operadores**,
usando la replicación nativa de PostgreSQL (streaming replication) con la siguiente
convención:

- **Pod ordinal 0** → Primary (lectura/escritura)
- **Pod ordinal 1+** → Replica(s) (solo lectura, standby hot)

Un script de entrypoint detecta el ordinal del pod y configura PostgreSQL
como primary o como replica automáticamente.

## Qué resuelve y qué NO resuelve

### Resuelve:
- **Redundancia de datos**: la réplica tiene una copia completa y actualizada
- **Fallo de nodo del primary**: si el nodo del pod-0 cae, la réplica sigue
  sirviendo lecturas. El primary se reprograma automáticamente por Kubernetes.
- **Menor RTO**: si el PVC del primary se corrompe, la réplica ya tiene los datos
- **Read offloading**: Keycloak/3scale pueden leer de la réplica (si se configura)

### NO resuelve (tradeoffs aceptados):
- **NO hay failover automático**: si pod-0 muere, pod-1 NO se promueve solo.
  Kubernetes reprograma pod-0 en otro nodo y arranca con el mismo PVC.
- **Promoción manual**: si el PVC de pod-0 se destruye, hay que promover
  la réplica manualmente (procedimiento documentado abajo).
- **Primary fijo**: pod-0 siempre es el primary. No hay elección de líder.

Esto es un compromiso razonable para bases de datos de plataforma interna
donde el downtime de 5-10 minutos es aceptable.

## Archivos

```
01-replication-secret.yaml      → Credenciales del usuario de replicación
02-configmap-scripts.yaml       → Script de entrypoint y configuración PG
03-headless-service.yaml        → Headless Service para DNS entre pods
04-services-rw-ro.yaml          → Services separados: primary (rw) y replicas (ro)
05-statefulset-keycloak.yaml    → StatefulSet con 2 réplicas
```

## Cómo migrar el StatefulSet existente

El procedimiento para pasar del StatefulSet actual (1 réplica, sin HA) al nuevo:

1. Escalar el StatefulSet actual a 0 réplicas (downtime breve)
2. Aplicar los nuevos manifiestos (Secret, ConfigMap, Services)
3. Reemplazar el StatefulSet con la nueva definición
4. La nueva definición sube pod-0 con la misma PVC existente (datos intactos)
5. Pod-1 arranca, hace pg_basebackup desde pod-0, y comienza a replicar

## Promoción manual de réplica (procedimiento de emergencia)

Si pod-0 se pierde irrecuperablemente y necesitas promover pod-1:

```bash
# 1. Escalar a 0
oc scale statefulset pg-keycloak --replicas=0 -n produbanco-databases

# 2. Eliminar el PVC del pod-0 corrupto
oc delete pvc pgdata-pg-keycloak-0 -n produbanco-databases

# 3. Conectarse al pod-1 y promover
oc exec -it pg-keycloak-1 -n produbanco-databases -- \
  pg_ctl promote -D /var/lib/pgsql/data/userdata

# 4. Renombrar el PVC de pod-1 a pod-0 (o recrear el StatefulSet)
#    Esto requiere un poco más de trabajo - ver notas al final del README.
```
