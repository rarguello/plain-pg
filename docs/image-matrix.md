# Image and version matrix

The image is pinned in one place: `manifests/components/image/kustomization.yaml`.

**Supported: `rhel10/postgresql-18`.** Everything else in the table is tested but
not supported.

| Image | PostgreSQL | Suite | Transcript |
|---|---|---:|---|
| `rhel10/postgresql-18` | 18 | 32/32 | [2026-10-16](evidence/2026-10-16-full-suite.txt) |
| `rhel9/postgresql-18` | 18 | pending | — |
| `rhel9/postgresql-16` | 16 | pending | — |
| `rhel10/postgresql-16` | 16 | pending | — |
| `rhel9/postgresql-15` | 15 | pending | — |

What the registry has: rhel9 publishes 13, 15, 16 and 18; rhel10 publishes 16 and
18. There is no 14, no 17 and no 19 (19 is still at RC upstream). PostgreSQL 13 is
end of life upstream, so it is not in the table.

## Running another one

```bash
./scripts/test-image.sh rhel9/postgresql-16
```

It pins that image temporarily (and restores the pin), wipes the PGDATA PVCs —
another image means another data directory — runs the full suite and leaves the
transcript in `docs/evidence/`.

To change the image for real, edit the pin
(`manifests/components/image/kustomization.yaml`): `newName` and `digest`
(`scripts/update-digest.sh --apply` updates the digest of the same image), then
recreate the pods; wipe the PVCs if the major version changes.

## Streaming replication across versions

From the release notes: the mechanism this repo uses is stable from PostgreSQL 12
on (`standby.signal`, `primary_conninfo`, `pg_basebackup`, WAL streaming,
`pg_stat_replication`). What moved near it: 13 renamed `wal_keep_segments` to
`wal_keep_size` and made `primary_conninfo` reloadable; 15 took `CREATE` on the
`public` schema away from `PUBLIC` (this is why the restore runs as the app user);
16 removed `promote_trigger_file`; 17 added `pg_basebackup --incremental`; 18
enables data checksums by default and deprecates MD5 passwords.
