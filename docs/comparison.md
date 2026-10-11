# Comparison with other ways to run PostgreSQL on Kubernetes

`plain-pg` is a small, operatorless setup. It is not a replacement for an
operator; the point of this page is to decide when it is enough and what you
give up.

Solutions compared (all real, widely used options):

- **plain-pg** — this repo: StatefulSet + Services + scripts, no operator.
- **CloudNativePG** — the most used PostgreSQL operator today (CNCF).
- **Zalando postgres-operator** — Patroni-based, from Zalando.
- **Crunchy PGO** — Patroni + pgBackRest, enterprise-oriented.
- **Bitnami `postgresql-ha`** — a Helm chart with repmgr + pgpool-II, no operator.
- *(mentioned in prose: StackGres, Percona, plain Patroni, and managed services)*

## Capability table

| | plain-pg | CloudNativePG | Zalando | Crunchy PGO | Bitnami chart |
|---|---|---|---|---|---|
| Form | StatefulSet + scripts | Operator + `Cluster` CRD | Operator + `postgresql` CRD | Operator + `PostgresCluster` CRD | Helm chart (no operator) |
| Leader election | Explicit: a ConfigMap says who is primary | Automatic (instance manager) | Patroni + DCS | Patroni + DCS | repmgr |
| Failover | Manual; optional best-effort CronJob | Automatic | Automatic | Automatic | Automatic (repmgr) |
| Fencing | Pod-level, verifiable, **not** STONITH | Operator-driven | DCS-driven | DCS-driven | repmgr |
| Rejoin of the old primary | Full re-seed (`pg_basebackup`) | `pg_rewind` (incremental) | `pg_rewind` | `pg_rewind` | re-seed |
| Synchronous replication | Manual (`ALTER SYSTEM`) | Declarative | Declarative | Declarative | Declarative |
| Backups / PITR | `pg_dump` CronJob, no PITR | Barman Cloud: base + WAL, PITR | WAL-G/WAL-E, PITR | pgBackRest, PITR | `pg_dump`/WAL-G |
| Metrics | Not included (add an exporter) | Built-in | Built-in | Built-in | Basic |
| Major version upgrades | Manual | Orchestrated | Orchestrated | Orchestrated | Manual |
| Connection pooling | No | PgBouncer (optional) | Connection pooler | PgBouncer | pgpool-II |
| Read load balancing | `postgresql-r` Service (all instances) | `-r` Service | Service + pooler | Service + pgBouncer | pgpool-II |
| Autoscaling | HPA on the StatefulSet (CPU) | HPA / `Cluster` scale | HPA | HPA | Replica count |
| OpenShift | Yes (UBI image, SCC `restricted`) | Yes | Yes | Yes (certified) | Yes |
| Things to run | 2 pods + 2 CronJobs | Operator + CRDs | Operator + CRDs | Operator + CRDs | Chart (many pods) |
| Main risk | Split-brain if a node partitions; async loss | Operator complexity | DCS dependency | Operator + pgBackRest complexity | pgpool-II as extra hop |

## When to use which

**Use `plain-pg` if:**

- you want to read every moving part and control it yourself;
- it is a lab, an internal platform, or a teaching reference;
- an RTO of minutes and losing the last unreplicated transaction are acceptable;
- you cannot install an operator (no CRD permissions, or you do not want one);
- the requirement is really "one hot replica, real backups, and a documented
  failover", not "five nines".

**Use an operator if:**

- you need failover you can trust without a human, including under node
  partitions;
- you need PITR (restore to a point in time) or retention in object storage;
- you run many clusters and want the whole lifecycle declared in Git;
- you want metrics, pooling, and orchestrated major upgrades out of the box;
- you need the old primary to rejoin with `pg_rewind` instead of a full copy.

**Rule of thumb:** if a database outage costs money or the data loss window
matters, use CloudNativePG (or Crunchy/Zalando if you already run them). If you
want to understand and own a minimal replication setup, use this.

## One line each on the others

- **StackGres** — Patroni-based operator with a UI, oriented to larger platforms.
- **Percona Operator** — Patroni + pgBackRest, similar shape to Crunchy.
- **Plain Patroni** (no operator) — the classic "operatorless HA": you run
  Patroni plus a DCS (etcd/Consul/Kubernetes API). More moving parts than
  `plain-pg`, but real consensus-based failover.
- **Managed services** (RDS, Aurora, Cloud SQL, Azure Database) — if you are not
  required to run the database inside your own cluster, they are usually the
  cheapest way to get real HA and PITR. This repo is for when the database must
  live in your cluster.

## What this repo borrows from operators

- The idea that exactly one instance is primary and the rest are replicas, and
  that the role must be explicit and auditable.
- Self-correction: a pod that does not match its assigned role moves itself to
  that role at startup.
- Backups as a Kubernetes object (a CronJob), not a host cron job.

What it deliberately does **not** borrow is the part that makes operators
complex: consensus-based leader election, `pg_rewind`, and WAL archiving. Those
are exactly the features you give up by not using one.
