# Supported images

The PostgreSQL image is pinned in one place:
`manifests/components/image/kustomization.yaml`. Every resource refers to it by
the logical name `postgresql`; that file maps the name to a real image and a
digest.

**Supported: `rhel10/postgresql-18`.** The other images below have passed the same
suite, but they are not supported.

| Image | PostgreSQL | Suite | Transcript |
|---|---|---:|---|
| `rhel10/postgresql-18` | 18 | 32/32 | [2026-10-16](evidence/2026-10-16-full-suite.txt) |
| `rhel9/postgresql-18` | 18 | 32/32 | [2026-10-17](evidence/2026-10-17-rhel9-postgresql-18-full-suite.txt) |
| `rhel9/postgresql-16` | 16 | 32/32 | [2026-10-17](evidence/2026-10-17-rhel9-postgresql-16-full-suite.txt) |
| `rhel10/postgresql-16` | 16 | 32/32 | [2026-10-17](evidence/2026-10-17-rhel10-postgresql-16-full-suite.txt) |
| `rhel9/postgresql-15` | 15 | 32/32 | [2026-10-17](evidence/2026-10-17-rhel9-postgresql-15-full-suite.txt) |

Images published by Red Hat: RHEL 9 has PostgreSQL 13, 15, 16 and 18; RHEL 10 has
16 and 18. There is no 14, 17 or 19. PostgreSQL 13 is end of life upstream and is
not tested.

Each row is one full run of `tests/run-all.sh` against a freshly deployed lab with
that image. The transcript is the evidence; a run is only counted when it reports
`RESULT: ALL OK`.

A green run proves that a fresh install with that image works. It does not prove
that a migration from another major version is safe: the suite never upgrades an
existing data directory. For a real change, follow
[Changing the PostgreSQL image](operations.md#changing-the-postgresql-image).

## Testing another image

```bash
./scripts/test-image.sh rhel9/postgresql-16
```

The script pins that image temporarily, wipes the PGDATA PVCs (another image means
another data directory), resets the role and the Services, runs the full suite and
leaves the transcript in `docs/evidence/`. The pin is restored when it finishes.

To change the image of a real deployment, follow
[Changing the PostgreSQL image](operations.md#changing-the-postgresql-image).

## Streaming replication across PostgreSQL versions

The mechanism this repository uses is stable from PostgreSQL 12 on:
`standby.signal`, `primary_conninfo`, `pg_basebackup`, WAL streaming and
`pg_stat_replication`. Changes in that area, from the release notes:

| Version | Change | Effect here |
|---|---|---|
| 12 | `recovery.conf` replaced by `standby.signal` | the floor: promotion deletes that file |
| 13 | `wal_keep_segments` renamed to `wal_keep_size` | neither is set |
| 13 | `primary_conninfo` became reloadable | the pods are recreated anyway |
| 15 | `PUBLIC` lost `CREATE` on the `public` schema | the restore runs as the application user |
| 16 | `promote_trigger_file` removed | not used |
| 17 | `pg_basebackup --incremental` added | not used; re-seeds are full |
| 18 | data checksums enabled by default; MD5 deprecated | 13-17 clusters have no checksums |
