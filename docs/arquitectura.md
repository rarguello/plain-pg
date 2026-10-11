# Arquitectura

## Piezas

| Objeto | Para qué |
|---|---|
| `StatefulSet postgres` (2 réplicas) | Los pods de PostgreSQL y sus PVCs (`pgdata-postgres-N`). |
| `ConfigMap postgres-role` | **Fuente de verdad del rol**: la clave `PRIMARY_POD` dice qué pod debe ser primary. |
| `ConfigMap postgres-scripts` | Entrypoint y healthcheck de los pods. |
| `Service postgres-hl` | Headless: DNS estable por pod (`postgres-0.postgres-hl…`). |
| `Service postgres-rw` | Selecciona el pod primary (por `statefulset.kubernetes.io/pod-name`). |
| `Service postgres-ro` | Selecciona la réplica. |
| `CronJob postgres-backup` | `pg_dump` diario a un PVC. |
| `CronJob postgres-failover` | (Opcional) promueve una réplica si el primary no responde. |
| `NetworkPolicy postgres-ingress` | Solo se acepta 5432 desde pods del namespace. |

## El rol lo decide el ConfigMap, no el ordinal

`postgres-0` es primary **por convención**, no por código. Al arrancar, cada pod
lee `PRIMARY_POD` y se compara con su propio nombre:

- si coinciden → arranca como **primary**;
- si no → arranca como **réplica** del pod indicado.

Eso es lo que hace posible promover una réplica sin operador: se cambia
`PRIMARY_POD` y se recrean los pods. No hay elección de líder ni consenso; es
una decisión explícita y auditable.

## El pod se autocorrige

Antes de arrancar, el entrypoint mira el estado de `PGDATA` y lo lleva al rol
que le toca:

| rol deseado | estado de `PGDATA` | acción |
|---|---|---|
| primary | vacío | `initdb` + creación de usuarios (lo hace la imagen) |
| primary | standby (`standby.signal`) | se borra `standby.signal` → promueve |
| primary | primary | arranca |
| réplica | vacío | `pg_basebackup` desde el primary |
| réplica | primary | se vacía y se re-siembra con `pg_basebackup` |
| réplica | standby | arranca y refresca `primary_conninfo` |

Gracias a esto, recuperar un pod es "borralo y se arregla solo", y un failover
es "cambiá el rol y recreá los pods".

## Por qué se reutiliza la imagen de Red Hat

La imagen `rhel10/postgresql-18` ya trae todo lo que hace falta:

- `PGDATA=/var/lib/pgsql/data/userdata` y `initdb` con la configuración correcta;
- creación del usuario y la base de la app a partir de variables de entorno;
- `ALTER USER … WITH REPLICATION` para el usuario de replicación;
- soporte de UID arbitrario (OpenShift) vía `nss_wrapper`;
- `ENABLE_REPLICATION=true` agrega `wal_level`, `max_wal_senders`, `wal_keep_size`
  y `hot_standby=on`.

Nuestro entrypoint no reimplementa nada de eso: sourcea `common.sh` de la imagen
y sólo decide el rol.

**Detalle fino:** el primary usa `run-postgresql` (que arranca el server,
sourcea los hooks y crea usuarios), pero la réplica **no** puede usarlo: esos
hooks hacen `ALTER USER`, y en un standby (read-only) fallan y abortarían el
arranque. Por eso la réplica replica el final de `run-postgresql-slave` y hace
`exec postgres` directo.

## Services: por qué por nombre de pod

Kubernetes no permite expresar "todos menos el primary" con un selector. Por eso
`-rw` y `-ro` seleccionan por `statefulset.kubernetes.io/pod-name` (una etiqueta
que Kubernetes pone solo). Es simple y explícito, con un costo: **al promover una
réplica hay que reapuntar `-rw` y `-ro`** (lo hacen `scripts/failover-manual.sh`
y el CronJob de failover).

Con más de una réplica, `-ro` sólo cubre el `postgres-1`; para las demás usá su
DNS individual (`postgres-2.postgres-hl…`) o ampliá el selector.

## Decisiones que conviene conocer

- **`podManagementPolicy: Parallel`**: los pods se crean sin orden. Es
  necesario porque, después de un failover, el primary puede ser `postgres-1`:
  con `OrderedReady`, al recrear los dos pods el StatefulSet esperaría a que
  `postgres-0` (ahora réplica) esté listo antes de crear a `postgres-1`, y
  `postgres-0` a su vez espera a su primary → deadlock. Cada réplica espera al
  primary explícitamente en el entrypoint (`wait_for_primary`).
- **`updateStrategy: OnDelete`**: un `oc apply` no reinicia la base. Los cambios
  de template se aplican borrando pods a mano. (Consecuencia: `oc rollout status`
  no funciona en este StatefulSet.)
- **Replicación asíncrona**: por defecto no se espera a la réplica para confirmar
  escrituras. Ver [failover.md](failover.md) para el trade-off.
- **Sin slots de replicación**: se apoya en `wal_keep_size`. Si la réplica queda
  caída mucho tiempo, hay que re-sembrarla (`scripts/reseed-replica.sh`).
