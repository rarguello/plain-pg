# Notas técnicas

Detalles que cuestan tiempo si no se conocen.

## Imagen

- **PGDATA real** es `/var/lib/pgsql/data/userdata`, no `/var/lib/pgsql/data`.
  Lo fija `set_pgdata()` de `common.sh`; el PVC se monta en `/var/lib/pgsql/data`.
- La imagen UBI10 **no trae `hostname`**. Se usa `${HOSTNAME:-$(uname -n)}`.
- `start/set_passwords.sh` (hook de la imagen) ya hace
  `ALTER USER <replicador> WITH REPLICATION`, así que no hace falta otorgarlo.
- **La réplica no puede usar `run-postgresql`**: ese camino sourcea hooks que
  ejecutan `ALTER USER`, y en un standby (read-only) fallan y abortan el
  arranque. La réplica hace `exec postgres` directo, como `run-postgresql-slave`.
- `initdb` deja la autenticación local en `trust`, así que `psql` por socket
  dentro del pod funciona sin password.

## Digest de imagen

`registry.redhat.io/rhel10/postgresql-18:latest` es multi-arquitectura. El
digest que se fija en el overlay es el del **manifest list**, que es
independiente de la arquitectura. En el pod:

- `.status.containerStatuses[].image` → la referencia fijada (manifest list);
- `.status.containerStatuses[].imageID` → el digest de la imagen **amd64**, que
  es distinto.

Por eso no se pueden comparar entre sí. Para actualizar el pin:
`./scripts/actualizar-digest.sh --apply`.

## `oc apply` e idempotencia

En un StatefulSet con `volumeClaimTemplates`, `kubectl`/`oc apply` (client-side)
imprime `configured` en **cada** corrida aunque no cambie nada: el merge de tres
vías siempre arma un patch por el `status` del template de PVC. **No significa
que haya cambios.** La idempotencia real se comprueba con el `resourceVersion` de
los objetos (es lo que hace `tests/t09_idempotencia.sh`).

## `oc rollout status` no sirve con `OnDelete`

```
error: rollout status is only available for RollingUpdate strategy type
```

El StatefulSet usa `OnDelete` a propósito (una BD no se debe reiniciar por un
`oc apply`). Para esperar el despliegue hay que mirar los pods: ver
`wait_db_ready()` en `scripts/lib.sh`.

## Labels de pods auxiliares

Los Services seleccionan pods por etiqueta. Un pod de un CronJob que lleve
`app.kubernetes.io/name: postgresql` **entra como endpoint** de `postgres-hl`
(con `publishNotReadyAddresses: true` entra incluso antes de estar listo) y
rompe las conexiones. Por eso los pods de backup y failover usan
`app.kubernetes.io/name: pg-backup` / `pg-failover`. Hay un test de regresión
(`tests/t19_selectores.sh`).

## NetworkPolicy es aditiva

Las NetworkPolicy **sólo agregan** permisos: el tráfico se permite si *alguna*
policy que selecciona al pod lo permite. No se puede "denegar" agregando otra
policy; hay que quitar o ajustar la que permite. (Relevante si querés aislar un
pod: no alcanza con crear una policy vacía.)

## Sesión de réplica y `primary_conninfo`

`postgresql.auto.conf` (en el PVC) incluye un archivo de recovery que vive en
`$HOME` (fuera del PVC, se pierde al recrear el contenedor). El entrypoint hace
`touch` de ese archivo en cada arranque para que el `include` no falle; si no,
PostgreSQL no arranca por "could not open configuration file".

## La API de Kubernetes devuelve JSON con indentación

Un `curl` "pelado" contra la API devuelve el JSON **multilínea** (`{\n  "kind": …`),
a diferencia de `oc get --raw`. Si se parsea con `grep -o '"clave":"valor"'` no
matchea nunca. El controlador de failover compacta la respuesta antes de parsear
(`tr -d ' \n\r\t'`) y manda sus logs a **stderr** para no contaminar el cuerpo
capturado en una command substitution.

## Autenticación local vs remota

`initdb` deja las conexiones **locales** (socket unix, 127.0.0.1, ::1) en
`trust`, y la imagen agrega al final `host all all all md5` y
`host replication all all md5`. Como pg_hba se evalúa de arriba hacia abajo:

- desde **dentro del pod** (127.0.0.1) no hace falta password: equivale a tener
  shell en el contenedor;
- desde **otro pod** (IP del pod) la primera línea que matchea es
  `host all all all md5`, así que la password es obligatoria.

Si querés cerrar también el acceso local, cambiá esas líneas a `scram-sha-256`
en `pg_hba.conf` (se puede hacer con un hook `postgresql-start`).

## Timeouts de conexión

Contra un primary aislado por red, una conexión TCP sin timeout puede tardar
~2 minutos (reintentos SYN del kernel). Por eso el controlador de failover usa
`PGCONNECT_TIMEOUT=5` y `curl --connect-timeout 5 --max-time 30`. Sin eso, el
health check "cuelga" en vez de fallar rápido.

## `podManagementPolicy: Parallel`

Con `OrderedReady`, si el primary es `postgres-1` (después de un failover) y se
recrean los dos pods a la vez, el StatefulSet espera a `postgres-0` (réplica)
para crear a `postgres-1`, y `postgres-0` espera a su primary → deadlock. Por eso
es `Parallel` y la espera al primary es explícita en el entrypoint.

## Reaplicar manifiestos después de un failover

El overlay declara `PRIMARY_POD=postgres-0` y los selectores originales, porque
ese es el estado *inicial*. `deploy.sh` guarda el estado operativo actual
(ConfigMap + selectores) y lo restaura después de aplicar, para no revertir un
failover. Para volver al estado inicial a propósito: `deploy.sh --reset-role`.
