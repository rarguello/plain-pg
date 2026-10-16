# Image and version matrix — investigation

**Date:** 2026-10-16 · **Status:** investigation only. Nothing here is fixed, and
the repo still ships the single combination it tests: `rhel10/postgresql-18`.

Question: from which platform (UBI 9 / UBI 10) and which PostgreSQL version can
this repo claim support, and what breaks in each combination?

## 1. What exists in the registry

Red Hat publishes PostgreSQL **only** as RHEL images. There is no
`ubi9/postgresql-*` or `ubi10/postgresql-*` (checked: absent).

| Repository | Exists | PostgreSQL | Platform label |
|---|---|---|---|
| `rhel9/postgresql-13` | yes | 13 | `el9` |
| `rhel9/postgresql-14` | **no** | — | — |
| `rhel9/postgresql-15` | yes | 15 | `el9` |
| `rhel9/postgresql-16` | yes | 16 | `el9` |
| `rhel9/postgresql-17` | **no** | — | — |
| `rhel9/postgresql-18` | yes | 18 | `el9` |
| `rhel10/postgresql-15` | **no** | — | — |
| `rhel10/postgresql-16` | yes | 16 | `el10` |
| `rhel10/postgresql-17` | **no** | — | — |
| `rhel10/postgresql-18` | yes | 18 | `el10` |
| any `postgresql-19` | **no** (19 is at RC1 upstream) | — | — |

The gaps are real, not a naming accident: Red Hat ships one PostgreSQL stream per
platform generation (RHEL 9 kept 13/15/16/18, RHEL 10 started at 16).

**UBI vs RHEL.** The user's rule is "UBI, not RHEL". There is no UBI PostgreSQL
image to use: UBI (the base OS) does not ship the server, and every Red Hat
PostgreSQL image is a RHEL image — the label says so:

- `cpe:/a:redhat:enterprise_linux:9::appstream` (rhel9: PostgreSQL as an AppStream
  module) and `cpe:/o:redhat:enterprise_linux:10.2` (rhel10: OS content, no
  modules).
- `com.redhat.license_terms` points at the **RHEL EULA** (`…#rhel`).

That is the "excellent reason" to keep a RHEL image: it is the only supported,
patched, Red Hat-built PostgreSQL. The alternative — building our own from UBI +
packages or source — means owning the build, the CVE flow and the support story,
and UBI alone does not provide `postgresql-server`. **This is a decision, not a
defect**, and it is the one thing the investigation could not solve technically.

## 2. Static facts (all combinations)

All images share the same shape — same user, same entrypoint, same layout — so
nothing in the manifests is version- or platform-specific:

| | rhel9/postgresql-13 | rhel9/…-15 | rhel9/…-16 | rhel9/…-18 | rhel10/…-16 | rhel10/…-18 |
|---|---|---|---|---|---|---|
| `PLATFORM` | el9 | el9 | el9 | el9 | el10 | el10 |
| user | 26 | 26 | 26 | 26 | 26 | 26 |
| entrypoint | `container-entrypoint` + `run-postgresql` (all six) |
| `APP_DATA` / `HOME` | `/opt/app-root` / `/var/lib/pgsql` (all six) |
| license | RHEL EULA (all six) |
| built | 2026-10-14 (all six) |

## 3. Runtime probe (all six, on the lab)

Each combination was deployed from scratch (fresh PVCs, the HA profile, two pods)
and checked. **All six came up and replicated**:

| Combination | `version()` | `data_directory` | roles | streaming |
|---|---|---|---|---|
| rhel9/postgresql-13 | 13.23 | `/var/lib/pgsql/data/userdata` | f / t | 1 |
| rhel9/postgresql-15 | 15.19 | `/var/lib/pgsql/data/userdata` | f / t | 1 |
| rhel9/postgresql-16 | 16.15 | `/var/lib/pgsql/data/userdata` | f / t | 1 |
| rhel9/postgresql-18 | 18.6 | `/var/lib/pgsql/data/userdata` | f / t | 1 |
| rhel10/postgresql-16 | 16.15 | `/var/lib/pgsql/data/userdata` | f / t | 1 |
| rhel10/postgresql-18 | 18.6 | `/var/lib/pgsql/data/userdata` | f / t | 1 |

`PGDATA` is `/var/lib/pgsql/data/userdata` in every version (our manifests and
the tests hardcode that path, and it holds), the container user is 26 everywhere,
and `PLATFORM` is `el9` or `el10` as expected. So the **entrypoint, the PVC
layout, the replication setup and the Services are not what limits the matrix**.

## 4. Problems detected (not fixed)

1. **The suite is written for one combination.** `t18_image` asserts
   `PLATFORM=el10`, the repository `rhel10/postgresql-18` and "postgres is 18.x";
   it would fail on any other combination even though the deployment works. The
   overlay also pins the digest in nine files (`images:` in each overlay), so a
   matrix would need one overlay per combination or an `images` parameter.
2. **Nothing in the docs states a supported range.** `README.md` and `AGENTS.md`
   say "UBI"/"the image", without a version floor or ceiling.
3. **The digest is behind the registry** (issue #4, opened by the drift job):
   the repo pins `sha256:2e04d97c…`, `:latest` is `sha256:b177f67c…`
   (built 2026-10-14). Not a version problem, but it shows the pin is not
   automatically current.
4. **PostgreSQL 13 is out of upstream support** (EOL 2025-11), so
   `rhel9/postgresql-13` exists but should not be a target for new work.
5. **The RHEL licence question** (section 1) is unresolved and is the real
   blocker for "UBI only".

## 5. What PostgreSQL changed in streaming replication (12 → 18)

Checked against the official release notes; this is what our design depends on
and what moved around it.

**The mechanism is stable from PostgreSQL 12 on** — `standby.signal` +
`primary_conninfo` + `pg_basebackup` + WAL streaming + `pg_stat_replication` /
`pg_stat_wal_receiver` / `pg_is_in_recovery()`. That is our floor: in **12**
`recovery.conf` was removed and replaced by `standby.signal` (our entrypoint
removes that file to promote), so **the repo cannot support anything older than
12** — and Red Hat ships nothing older than 13.

Changes that touch the edges of what we do:

| Version | Change | Effect on us |
|---|---|---|
| 12 | `recovery.conf` gone; `standby.signal` + settings in `postgresql.conf` | our floor |
| 12 | `pg_promote()` added; `promote_trigger_file` (from `trigger_file`) | we promote by deleting `standby.signal`, unaffected |
| 12 | `max_wal_senders` no longer counted in `max_connections` | none |
| 13 | `wal_keep_segments` renamed to `wal_keep_size` (MB) | we set neither |
| 13 | `primary_conninfo` reloadable (12 needed a restart) | we rewrite it and restart the pod, works on both |
| 13 | default minimum TLS version 1.0 → 1.2 | our TLS tests pass on 13+ |
| 13 | `pg_stat_ssl` no longer lists auxiliary processes | our `pg_stat_ssl` joins still work |
| 15 | `public` schema loses `PUBLIC CREATE`; owner becomes `pg_database_owner` | **matters for our restore path**: on 15+ a restore must run as the owner (that is why the DR drill restores as the app user) |
| 16 | `promote_trigger_file` **removed** | none (we do not use it) |
| 16 | `pg_hba.conf` gains regex rules and `include` directives | our in-place `host` → `hostssl` rewrite would not touch an included file |
| 17 | `pg_basebackup --incremental` + `pg_combinebackup` + WAL summarization | an alternative to our full re-seed; unused |
| 17 | `pg_stat_bgwriter` loses `buffers_backend*`; `pg_stat_checkpointer` added | monitoring only |
| 18 | `initdb` enables **data checksums by default** | a real difference: 13–17 clusters have none, 18 has them; `pg_upgrade` requires matching |
| 18 | MD5 password auth deprecated (removal announced) | we use scram; fine for now |
| 18 | `idle_replication_slot_timeout`, `max_active_replication_origins` | we use no slots |

Nothing in 13 → 18 breaks the way this repo promotes, seeds or streams. The
differences that could bite are operational: the `public` schema change on 15+
(already handled in the restore path) and the `pg_hba.conf` include caveat on 16+.

## 6. What we can claim today

- **Tested:** `rhel10/postgresql-18` (the pin) on OpenShift 4.21 — the full suite.
- **Probed, not tested:** the five other combinations above — they deploy and
  replicate, but the suite was not run against them, and its assertions assume
  el10/18.
- **Not available:** UBI PostgreSQL (does not exist), PostgreSQL 14/17 (no image),
  19 (no image yet).
- **Would not claim:** `rhel9/postgresql-13` for new deployments (EOL upstream).

## 7. How to reproduce

```bash
# what exists and what each image declares
skopeo inspect --authfile ~/.pull-secret.json docker://registry.redhat.io/rhel9/postgresql-16

# one combination on the lab (destructive: wipes the DB PVCs)
oc -n plain-pg delete sts postgresql --wait=true
oc -n plain-pg delete pvc pgdata-postgresql-0 pgdata-postgresql-1 --wait=true
oc apply -k manifests/overlays/lab
oc -n plain-pg set image sts/postgresql postgresql=registry.redhat.io/rhel9/postgresql-16@sha256:…
oc -n plain-pg delete pod postgresql-0 postgresql-1
oc -n plain-pg exec postgresql-0 -- psql -U postgres -tAc 'SELECT version()'
```

Switching major versions always needs fresh PVCs: PostgreSQL refuses to start on
a data directory from another major version, so the teardown above is part of the
procedure, not an accident.
