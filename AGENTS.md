# AGENTS.md — rules for `plain-pg`

Guidance for any agent (OpenCode, Codex) or person working in this repo.

## What this is

PostgreSQL streaming replication on OpenShift with plain Kubernetes objects:
1 primary (`postgresql-0`) + 1 hot standby, an optional automatic-failover
CronJob, `pg_dump` backups, an optional read HPA, and a test suite in `tests/`.
Details and commands: `README.md`.

## Hard rules

1. **No operators, no CRDs.** Core objects only.
2. **No secrets in git.** Never commit the `postgresql-credentials` Secret or its
   values. A real deploy is given one by hand or by an ExternalSecret; the test
   tooling generates a throwaway one in gitignored `secrets/`.
3. **The image must be UBI** (`registry.redhat.io/...`), pinned by digest. (The
   metrics exporter in `components/metrics` is the one documented exception: Red
   Hat publishes no UBI exporter; see the allowlist in `tools/check-policies.py`.)
4. **Test namespace: `plain-pg`.** Do not touch other namespaces.
5. **Do not hardcode a StorageClass** unless it is unavoidable (and document it).
6. **Everything documented was tested.** No untested procedures.
7. **Idempotency:** every script must survive being run twice.
8. **Only `postgresql-0` and `postgresql-1` may be primary.** Auxiliary pods must
   not carry `app.kubernetes.io/name: postgresql` or `instance: postgresql`, or
   they become endpoints of the database Services.

## Conventions

- Documentation and comments in **English**; identifiers and log messages too.
- Resource prefix `postgresql-`; common `app.kubernetes.io/{name,instance,part-of,component}` labels.
- Real `PGDATA`: `/var/lib/pgsql/data/userdata`.
- Template changes require deleting pods by hand (`updateStrategy: OnDelete`).
- Keep it small. This repo is meant to be read in one sitting: prefer deleting a
  script or a section over adding one.

## Workflow

1. Read `docs/` before proposing changes.
2. One commit per logical step, clear message.
3. Apply to the cluster and verify with evidence.
4. Run `./tests/run-all.sh quick` before closing a step; the full
   `./tests/run-all.sh` before a release (it is destructive). Record fresh output
   in `docs/evidence/`.
5. Update the affected documentation in the same commit.
6. Have Codex review each milestone (YAML/scripts, split-brain or data-loss risks,
   idempotency, consistency with these rules).
