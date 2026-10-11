# plain-pg

**PostgreSQL with a hot replica on OpenShift, using plain Kubernetes objects.
No operator, no CRDs, no console.**

A StatefulSet with 2 pods: `postgresql-0` is the primary, `postgresql-1` a hot
standby. The image is **PostgreSQL 18 on UBI**
(`registry.redhat.io/rhel10/postgresql-18`), pinned by digest. Which pod is
primary is decided by a ConfigMap, so promoting a replica is changing a value
and recreating pods — no controller required.

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

## What it is

- Native PostgreSQL streaming replication, configured by scripts.
- It reuses Red Hat's image machinery (`run-postgresql`, its hooks,
  `ENABLE_REPLICATION`): `initdb` and user creation are not reimplemented.
- Four Services: `-rw` (primary), `-r` (all instances, load-balanced reads),
  `-ro` (replica), `-hl` (per-pod DNS).
- **Manual failover** documented, plus an **optional** automatic failover
  CronJob with verifiable pod-level fencing.
- **Logical backups** (`pg_dump`/`pg_dumpall`) with retention and a verified
  restore path.
- **Optional read autoscaling** (HPA) that pairs with `postgresql-r`.
- Kustomize overlays, a `Makefile`, and a test suite that runs against a real
  cluster.

## What it is not

- **Not an operator.** No CRDs, no continuous reconciliation, no console. If you
  need that, use [CloudNativePG](https://cloudnative-pg.io/) or another operator
  — see [docs/comparison.md](docs/comparison.md) for an honest side-by-side.
- **Not PITR.** Backups are logical dumps; there is no WAL archiving.
- **Not production-grade HA.** The automatic failover fences at the *pod* level,
  which is not STONITH: a node partition can still produce two primaries. Reads
  from a replica can also lag, and an async failover can lose the last
  unreplicated transactions. Read [docs/failover.md](docs/failover.md) before
  trusting it with anything that matters.
- **No consensus leader election.** The primary is whoever the ConfigMap says.

## Quick start

You need `oc` (or `kubectl`) logged into a cluster, and `git`. Nothing else.

```bash
git clone https://github.com/<you>/plain-pg.git && cd plain-pg

./scripts/deploy.sh              # full overlay (with automatic failover)
./scripts/verify-replication.sh  # checks the replica is up to date
```

There is a `Makefile` too: `make deploy`, `make verify`, `make lint`,
`make test-quick`, `make test`.

Reads-only + manual failover (no failover CronJob):

```bash
./scripts/deploy.sh manifests/overlays/lab-manual
```

Tear down:

```bash
./scripts/teardown.sh        # resources, PVCs and the Secret (keeps the namespace)
./scripts/teardown.sh --all  # the whole namespace
```

## Using it

```bash
# writes (always the primary)
psql "postgresql://app:PASS@postgresql-rw.postgresql-lab.svc:5432/appdb"

# reads, spread over all instances
psql "postgresql://app:PASS@postgresql-r.postgresql-lab.svc:5432/appdb"

# reads, replica only
psql "postgresql://app:PASS@postgresql-ro.postgresql-lab.svc:5432/appdb"

# replication status
oc -n postgresql-lab exec postgresql-0 -- psql -U postgres -c 'SELECT * FROM pg_stat_replication;'

# backups
./scripts/backup-now.sh
./scripts/restore-backup.sh /backups/<file>.dump my_restored_db

# failover
./scripts/failover-manual.sh

# read load + autoscaling demo
./scripts/deploy.sh manifests/overlays/lab-autoscale
./scripts/read-load.sh 180 12
```

## Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How it works inside, and why |
| [docs/operations.md](docs/operations.md) | Deploy, verify, day-to-day tasks |
| [docs/failover.md](docs/failover.md) | Manual and automatic failover, limits |
| [docs/backups.md](docs/backups.md) | Backups, retention, restore |
| [docs/scaling.md](docs/scaling.md) | Read balancing and the HPA |
| [docs/scenarios.md](docs/scenarios.md) | "What happens if…" matrix |
| [docs/use-cases.md](docs/use-cases.md) | When to use it and when not |
| [docs/comparison.md](docs/comparison.md) | Side-by-side with the popular operators |
| [docs/tests.md](docs/tests.md) | How to run the test suite, and results |
| [docs/technical-notes.md](docs/technical-notes.md) | Sharp edges (multi-arch digest, `oc apply`, …) |

## Layout

```
manifests/
  base/                 shared objects (kustomize)
  components/           optional add-ons (automatic failover, read scaling)
  overlays/lab/         full deployment            (postgresql-lab)
  overlays/lab-manual/  manual failover only
  overlays/lab-autoscale/  lab + HPA
scripts/                deploy, teardown, verify, failover, backup, restore, read-load
tests/                  test suite (t01…t23) + runner
tools/                  static validation of the embedded scripts
docs/                   documentation
```

## License

MIT. See [LICENSE](LICENSE).
