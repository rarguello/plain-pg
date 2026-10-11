# plain-pg

PostgreSQL streaming replication on OpenShift with plain Kubernetes objects: no
operator, no CRDs, no console. A two-pod StatefulSet where the `postgresql-role`
ConfigMap decides which pod is primary, so a failover is changing a value and
recreating pods.

```
writes ──▶ postgresql-rw ──▶ postgresql-0  [PRIMARY]  ──▶ PVC pgdata-postgresql-0
reads  ──▶ postgresql-r  ──▶ every Ready instance (load-balanced)
reads  ──▶ postgresql-ro ──▶ postgresql-1  [STANDBY]  ──▶ PVC pgdata-postgresql-1
                                  ▲
                   WAL streaming  │   postgresql-hl: per-pod DNS

CronJob postgresql-backup   ──▶ pg_dump ──▶ PVC postgresql-backups
CronJob postgresql-failover ──▶ promotes a replica if the primary stops answering
HPA postgresql-read         ──▶ grows the read fleet under load (optional)
```

## How the role works

`postgresql-0` is primary by convention, not by code. On startup each pod reads
`PRIMARY_POD` and, if it matches its own name, starts as primary; otherwise it
starts as a replica of the named pod. There is no leader election: the role is an
explicit value you change on purpose.

The entrypoint also brings `PGDATA` to the assigned role:

| desired | `PGDATA` holds | action |
|---|---|---|
| primary | empty | `initdb` + user creation (done by the image) |
| primary | standby | delete `standby.signal` → promote |
| replica | empty | `pg_basebackup` from the primary |
| replica | primary | wipe and re-seed |
| replica | standby | start and refresh `primary_conninfo` |

So recovering a pod is "delete it and it fixes itself", and a failover is "change
the role and recreate the pods".

## Quick start

You need `oc` logged into a cluster, `git`, and Python with PyYAML (the last one
only when re-applying over an existing deployment).

```bash
git clone https://github.com/rarguello/plain-pg.git && cd plain-pg
./scripts/deploy.sh              # full overlay (with automatic failover)
./scripts/verify-replication.sh  # checks the replica is up to date
```

Manual failover only (no failover CronJob):
`./scripts/deploy.sh manifests/overlays/lab-manual`.

Tear down: `./scripts/teardown.sh` (keeps the namespace) or `./scripts/teardown.sh --all`.
There is a `Makefile`: `make deploy`, `verify`, `lint`, `test-quick`, `test`.

## Limits

Read this before trusting it with data that matters.

| Limit | Consequence |
|---|---|
| Fencing is pod-level, not STONITH | a node partitioned from the API server can leave two primary processes |
| Replication is asynchronous | a failover can lose the last unreplicated transactions |
| Backups are logical (`pg_dump`), no WAL archiving | no point-in-time recovery; the copies live in the cluster |
| No operator, no consensus | failover is manual or a best-effort CronJob, not automatic HA |

If you need automatic failover you can trust under node partitions, or PITR, use
an operator (CloudNativePG, Crunchy, Zalando) or Patroni instead of this.

## Documentation

- [docs/operations.md](docs/operations.md) — deploy, verify, connect, restart, re-seed
- [docs/failover.md](docs/failover.md) — manual and automatic failover, limits
- [docs/backups.md](docs/backups.md) — backups and restore
- [docs/scaling.md](docs/scaling.md) — reads and the HPA
- [docs/tests.md](docs/tests.md) — the test suite
- [docs/evidence/](docs/evidence/) — raw output of suite runs

## Layout

```
manifests/  base + components + overlays      scripts/  deploy, failover, backup, restore, ...
tests/      suite t01..t23 + runner           tools/    static validation of embedded scripts
```

MIT. See [LICENSE](LICENSE).
