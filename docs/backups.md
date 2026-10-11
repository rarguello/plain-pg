# Backups

**Logical** backups with the standard PostgreSQL tools. It is the simplest thing
that works and can be verified.

## How it works

`CronJob postgresql-backup` runs every day at 02:00 and runs
`scripts/backup.sh` (ConfigMap `postgresql-backup-scripts`):

1. `pg_dumpall --globals-only` → roles and users.
2. `pg_dump -Fc <database>` → app data, in custom format.
3. Verifies the dump with `pg_restore -l` (if it cannot be listed, the Job fails).
4. Deletes files older than `BACKUP_RETENTION_DAYS` days (default 7).

The files are left in the `postgresql-backups` PVC (`/backups`), apart from the
data PVC, so they survive a rebuild of the database.

The dump is made against the **`postgresql-rw`** Service, so it follows the current
primary automatically, even after a failover.

## Usage

```bash
# Manual backup (creates a Job from the CronJob and waits)
./scripts/backup-now.sh

# Restore into a NEW database (does not touch the app database)
./scripts/restore-backup.sh /backups/20261011-020000-appdb.dump my_db

# See what is there
oc -n postgresql-lab exec <job-pod> -- ls -lh /backups
```

## Verifying that a backup works

`restore-backup.sh` restores the dump into a database with another name and lists
the tables. It is the way to check that the backup is usable without touching production:

```bash
./scripts/restore-backup.sh /backups/<file>.dump verification
```

The test suite does exactly this (see `tests/t12_backup.sh`).

The `-globals.sql` file stores roles and users. `restore-backup.sh` restores
only the app database; the globals are left to be restored by hand if needed
(`psql -f <file>-globals.sql`).

## Settings

| Variable | Where | Default |
|---|---|---|
| `BACKUP_RETENTION_DAYS` | `CronJob postgresql-backup` | `7` |
| `BACKUP_HOST` | `CronJob postgresql-backup` | `postgresql-rw` |
| `BACKUP_DIR` | `CronJob postgresql-backup` | `/backups` |

For an hourly backup, change the CronJob `schedule`. For read offload, set
`BACKUP_HOST=postgresql-ro` (the dump comes from the replica; it may be a few
seconds behind).

## What it does not cover

- **It is not PITR.** There is no WAL archiving, so you cannot restore "to
  14:32". That needs `archive_mode` + `archive_command` (for example to object
  storage) and a `restore_command`. It is a bigger step; logical backups cover
  the "I lost the database" case.
- **It is not uploaded outside the cluster.** If the PVC is lost, the backups are
  lost. For production, point the destination at external storage (S3/object
  storage with `s3cmd`/`aws-cli`, or a PVC with replication).
- **It does not `pg_dump` databases other than the app one.** If you add more
  databases, add a `pg_dump` per database in `backup.sh`.
