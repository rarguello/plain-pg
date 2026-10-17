# Backups

Logical backups with the standard PostgreSQL tools. No WAL archiving.

## How it works

`CronJob postgresql-backup` runs daily at 02:00 (`scripts/backup.sh` in the
`postgresql-backup-scripts` ConfigMap):

1. `pg_dumpall --globals-only` → roles and users.
2. `pg_dump -Fc <database>` → app data, custom format.
3. Verifies the dump with `pg_restore -l` (the Job fails if it cannot be listed).
4. Deletes files older than `BACKUP_RETENTION_DAYS` (default 7).

The dump is taken against `postgresql-rw`, so it follows the current primary after
a failover. Files live on the `postgresql-backups` PVC (`/backups`), separate from
the data PVC, so they survive a rebuild of the database.

## Usage

```bash
./scripts/backup-now.sh
./scripts/restore-backup.sh /backups/20261011-020000-appdb.dump my_db
oc -n plain-pg exec <job-pod> -- ls -lh /backups
```

`restore-backup.sh` restores the dump into a **new** database (it refuses to
overwrite an existing one or to target the app database) and lists the tables.
That is how the test suite checks a backup without touching production
(`tests/t12_backup.sh`). The `-globals.sql` file holds roles and users and is
restored by hand (`psql -f <file>-globals.sql`).

With `FORCE=1` it drops and recreates the target instead, and the objects end up
owned by the application user. That is the disaster-recovery path: rebuild the
cluster, then load the last dump into the app database
(`tests/t30_dr_drill.sh`; see [operations.md](operations.md#recovery)).

## Settings

| Variable | Where | Default |
|---|---|---|
| `BACKUP_RETENTION_DAYS` | `CronJob postgresql-backup` | `7` |
| `BACKUP_HOST` | `CronJob postgresql-backup` | `postgresql-rw` |
| `BACKUP_DIR` | `CronJob postgresql-backup` | `/backups` |

Change the CronJob `schedule` for another frequency. Set
`BACKUP_HOST=postgresql-ro` to dump from the replica instead.

## Scope

No WAL archiving, so there is no point-in-time recovery ("restore to 14:32");
that needs `archive_mode`/`archive_command` and a `restore_command`. The PVC is
the only copy, so losing it loses the backups. Only the app database is dumped;
add a `pg_dump` per extra database in `backup.sh`. The Job checks that the dump
can be listed; only `restore-backup.sh` (and `t12`/`t30`) prove it actually restores.
