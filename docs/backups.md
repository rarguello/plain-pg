# Backups

Backups **lógicos** con las herramientas estándar de PostgreSQL. Es lo más
simple que sirve y se puede verificar.

## Cómo funciona

`CronJob postgres-backup` corre todos los días a las 02:00 y ejecuta
`scripts/backup.sh` (ConfigMap `postgres-backup-scripts`):

1. `pg_dumpall --globals-only` → roles y usuarios.
2. `pg_dump -Fc <basededatos>` → datos de la app, en formato custom.
3. Verifica el dump con `pg_restore -l` (si no se puede listar, el Job falla).
4. Borra los archivos con más de `BACKUP_RETENTION_DAYS` días (por defecto 7).

Los archivos quedan en el PVC `postgres-backups` (`/backups`), aparte del PVC de
datos, así sobreviven a un rebuild de la base.

El dump se hace contra el Service **`postgres-rw`**, por lo que sigue
automáticamente al primary actual, incluso después de un failover.

## Uso

```bash
# Backup manual (crea un Job a partir del CronJob y espera)
./scripts/backup-now.sh

# Restaurar en una base NUEVA (no toca la base de la app)
./scripts/restore-backup.sh /backups/20261011-020000-appdb.dump mi_base

# Ver qué hay
oc -n pg-ha-lab exec <pod-del-job> -- ls -lh /backups
```

## Verificar que un backup sirve

`restore-backup.sh` restaura el dump en una base con otro nombre y lista las
tablas. Es la forma de comprobar que el backup es usable sin tocar producción:

```bash
./scripts/restore-backup.sh /backups/<archivo>.dump verificacion
```

La batería de pruebas hace exactamente esto (ver `tests/t12_backup.sh`).

El archivo `-globals.sql` guarda roles y usuarios. `restore-backup.sh` restaura
sólo la base de la app; los globals quedan para restaurarlos a mano si hiciera
falta (`psql -f <archivo>-globals.sql`).

## Ajustes

| Variable | Dónde | Default |
|---|---|---|
| `BACKUP_RETENTION_DAYS` | `CronJob postgres-backup` | `7` |
| `BACKUP_HOST` | `CronJob postgres-backup` | `postgres-rw` |
| `BACKUP_DIR` | `CronJob postgres-backup` | `/backups` |

Para backup cada hora, cambiá el `schedule` del CronJob. Para offload de lecturas,
poné `BACKUP_HOST=postgres-ro` (el dump sale de la réplica; puede quedar unos
segundos atrás).

## Qué no cubre

- **No es PITR.** No hay archivado de WAL, así que no se puede restaurar "a las
  14:32". Para eso hace falta `archive_mode` + `archive_command` (por ejemplo a
  object storage) y un `restore_command`. Es un paso más grande; los backups
  lógicos cubren el caso "me quedé sin base".
- **No se sube fuera del cluster.** Si el PVC se pierde, se pierden los backups.
  Para producción, apuntá el destino a almacenamiento externo (S3/object storage
  con `s3cmd`/`aws-cli`, o un PVC con replicación).
- **No hace `pg_dump` de bases que no sean la de la app.** Si agregás más bases,
  sumá un `pg_dump` por base en `backup.sh`.
