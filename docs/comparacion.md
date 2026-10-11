# Comparación con un operador (CloudNativePG)

Este proyecto no reemplaza a un operador. La comparación sirve para decidir con
qué alcanza y qué se gana y se pierde.

[CloudNativePG (CNPG)](https://cloudnative-pg.io/) es el operador de PostgreSQL
para Kubernetes más usado hoy. Es una buena vara para medir.

| | pg-ha (este repo) | CloudNativePG |
|---|---|---|
| Qué es | StatefulSet + Services + scripts | Operador + CRD `Cluster` |
| Elección de líder | decisión explícita (ConfigMap) | automática (instancia primaria con heartbeat) |
| Detección de fallo | timeout de health check | heartbeats + instancia primaria designada |
| Failover | manual; automático *best-effort* por CronJob | automático, con reelección |
| Fencing | no | sí |
| Reincorporar el ex-primary | re-siembra completa (`pg_basebackup`) | `pg_rewind` (incremental) |
| Replicación sincrónica | manual (`ALTER SYSTEM`) | declarativa |
| Backups | `pg_dump` en un CronJob | Barman Cloud: base + WAL a object storage |
| PITR | no | sí |
| Métricas Prometheus | no (se puede agregar un exporter) | incluidas |
| Upgrades de versión | manuales | orquestados por el operador |
| Pooling | no | PgBouncer integrado |
| Réplicas de lectura / services | Services `-rw`/`-ro` | `-rw`, `-ro`, `-r` por instancia |
| Superficie de operación | 2 pods + 2 CronJobs | operador + CRDs + varias instancias |
| Curva de aprendizaje | baja | media |
| Riesgo principal | split-brain / pérdida en failover asíncrono | complejidad del operador |

## Cuándo elegir cada uno

**pg-ha** tiene sentido si:

- querés entender y controlar exactamente qué hace cada pieza;
- es una plataforma interna o un lab donde un RTO de minutos es aceptable;
- no querés instalar ni mantener un operador (o no tenés permiso para CRDs);
- el requisito es "una réplica caliente y un backup", nada más.

**CloudNativePG** (u otro operador) tiene sentido si:

- necesitás HA real con failover automático confiable;
- necesitás PITR o retención con object storage;
- manejás varios clusters y querés declarativo de punta a punta;
- querés métricas, pooling, upgrades orquestados "de fábrica".

## Lo que este repo sí toma de los operadores

- **La idea de "un pod es primary y el resto réplicas"**, y que el estado del rol
  debe ser explícito y auditable.
- **La autocorrección**: un pod que no coincide con el rol esperado se lleva a
  ese rol solo. Los operadores hacen esto en bucle; acá se hace al arrancar.
- **Backups desde un objeto de Kubernetes** (CronJob), no desde un cron del host.

## Otros operadores, en una línea

- **Zalando postgres-operator**: maduro, orientado a Patroni; más piezas
  (Patroni + etcd/Consul).
- **Crunchy PGO**: muy completo (PITR, pgBackRest, HA); más pesado.
- **StackGres**: sobre Patroni, con UI; apunta a plataformas grandes.

Todos resuelven el mismo problema que este repo deja deliberadamente abierto:
elección de líder con consenso y fencing.
