# Architecture

## Pieces

| Object | What it is for |
|---|---|
| `StatefulSet postgresql` (2 replicas) | The PostgreSQL pods and their PVCs (`pgdata-postgresql-N`). |
| `ConfigMap postgresql-role` | **Source of truth for the role**: the `PRIMARY_POD` key says which pod must be primary. |
| `ConfigMap postgresql-scripts` | Entrypoint and healthcheck for the pods. |
| `Service postgresql-hl` | Headless: stable per-pod DNS (`postgresql-0.postgresql-hl…`). |
| `Service postgresql-rw` | Selects the primary pod (by `statefulset.kubernetes.io/pod-name`). |
| `Service postgresql-ro` | Selects the replica. |
| `CronJob postgresql-backup` | Daily `pg_dump` to a PVC. |
| `CronJob postgresql-failover` | (Optional) promotes a replica if the primary does not respond. |
| `NetworkPolicy postgresql-ingress` | Only 5432 from pods in the namespace is accepted. |

## The role is decided by the ConfigMap, not the ordinal

`postgresql-0` is primary **by convention**, not by code. On startup, each pod
reads `PRIMARY_POD` and compares it with its own name:

- if they match → it starts as **primary**;
- if not → it starts as a **replica** of the named pod.

That is what makes it possible to promote a replica without an operator: change
`PRIMARY_POD` and recreate the pods. There is no leader election or consensus;
it is an explicit, auditable decision.

## The pod self-corrects

Before starting, the entrypoint looks at the state of `PGDATA` and brings it to
the role it is assigned:

| desired role | state of `PGDATA` | action |
|---|---|---|
| primary | empty | `initdb` + user creation (done by the image) |
| primary | standby (`standby.signal`) | `standby.signal` is deleted → promotes |
| primary | primary | starts |
| replica | empty | `pg_basebackup` from the primary |
| replica | primary | wiped and re-seeded with `pg_basebackup` |
| replica | standby | starts and refreshes `primary_conninfo` |

Thanks to this, recovering a pod is "delete it and it fixes itself", and a
failover is "change the role and recreate the pods".

## Why the Red Hat image is reused

The `rhel10/postgresql-18` image already brings everything needed:

- `PGDATA=/var/lib/pgsql/data/userdata` and `initdb` with the correct configuration;
- creation of the app user and database from environment variables;
- `ALTER USER … WITH REPLICATION` for the replication user;
- arbitrary UID support (OpenShift) via `nss_wrapper`;
- `ENABLE_REPLICATION=true` adds `wal_level`, `max_wal_senders`, `wal_keep_size`
  and `hot_standby=on`.

Our entrypoint reimplements none of that: it sources `common.sh` from the image
and only decides the role.

**Fine detail:** the primary uses `run-postgresql` (which starts the server,
sources the hooks and creates users), but the replica **cannot** use it: those
hooks run `ALTER USER`, and on a standby (read-only) they fail and would abort
startup. That is why the replica replicates the end of `run-postgresql-slave`
and does `exec postgres` directly.

## Services: why by pod name

Kubernetes does not allow expressing "all but the primary" with a selector. That
is why `-rw` and `-ro` select by `statefulset.kubernetes.io/pod-name` (a label
Kubernetes sets on its own). It is simple and explicit, at a cost: **promoting a
replica requires repointing `-rw` and `-ro`** (`scripts/failover-manual.sh` and
the failover CronJob do it).

With more than one replica, `-ro` only covers `postgresql-1`; for the others use
their individual DNS (`postgresql-2.postgresql-hl…`) or widen the selector.

## Decisions worth knowing

- **`podManagementPolicy: Parallel`**: pods are created out of order. It is
  necessary because, after a failover, the primary may be `postgresql-1`: with
  `OrderedReady`, when recreating both pods the StatefulSet would wait for
  `postgresql-0` (now a replica) to be ready before creating `postgresql-1`, and
  `postgresql-0` in turn waits for its primary → deadlock. Each replica waits for
  the primary explicitly in the entrypoint (`wait_for_primary`).
- **`updateStrategy: OnDelete`**: an `oc apply` does not restart the database.
  Template changes are applied by deleting pods by hand. (Consequence:
  `oc rollout status` does not work on this StatefulSet.)
- **Asynchronous replication**: by default the replica is not awaited to confirm
  writes. See [failover.md](failover.md) for the trade-off.
- **No replication slots**: it relies on `wal_keep_size`. If the replica is down
  for a long time, it must be re-seeded (`scripts/reseed-replica.sh`).
