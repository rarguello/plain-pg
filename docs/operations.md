# Operations

## Deploy

```bash
./scripts/deploy.sh                                 # full (with automatic failover)
./scripts/deploy.sh manifests/overlays/lab-manual   # manual failover only
```

`deploy.sh` needs `oc` and, when it reapplies over an existing deployment, Python
with PyYAML. It renders the overlay with Kustomize,
generates the Secret (random passwords, outside git) and waits for the pods to be
Ready. It is idempotent.

On an existing deployment it does **not** apply the `postgresql-role` ConfigMap
nor the `postgresql-rw`/`postgresql-ro` Services: that is operational state owned
by the failover scripts, and applying it would silently revert a failover. The
StatefulSet is applied server-side without `spec.replicas`, so `deploy.sh` never
writes a replica count and a concurrent HPA scale is left alone. To change those
values on a live cluster, patch them explicitly; to return to the initial primary,
fail back with `./scripts/failover-manual.sh postgresql-0`.

## Verify and connect

```bash
./scripts/verify-replication.sh
oc -n postgresql-lab get pods,pvc,svc
oc -n postgresql-lab exec postgresql-0 -- psql -U postgres -c 'SELECT * FROM pg_stat_replication;'
```

The credentials are in `secrets/postgresql-credentials.env` (not versioned).

```bash
NS=postgresql-lab
oc -n $NS exec -it postgresql-0 -- psql -h postgresql-rw -U app -d appdb   # writes
oc -n $NS exec -it postgresql-1 -- psql -h postgresql-ro -U app -d appdb   # reads
oc -n $NS exec -it postgresql-0 -- psql -h 127.0.0.1 -U postgres           # superuser
```

## Frequent tasks

```bash
oc -n postgresql-lab logs -f postgresql-0
oc -n postgresql-lab delete pod postgresql-1     # restart the replica (no impact)
oc -n postgresql-lab delete pod postgresql-0     # restart the primary (brief outage)
./scripts/backup-now.sh
./scripts/reseed-replica.sh postgresql-1         # re-seed a broken replica
```

Add a replica with `oc scale sts postgresql --replicas=3`. Scaling back leaves the
removed pod's PVC orphaned (`oc delete pvc pgdata-postgresql-N`). Do not scale by
hand while an HPA owns `replicas` (see `scaling.md`).

## Recovery

- **Replica fell too far behind** (log: `requested WAL segment … has already been
  removed`): `./scripts/reseed-replica.sh postgresql-1`.
- **Failed promotion**: the declared state stays on the candidate and the
  ex-primary is isolated. Finish it by hand (`oc delete pod <candidate>`) or roll
  back explicitly. See `failover.md`.
- **The primary and replica PVCs are both lost**: the dumps on the
  `postgresql-backups` PVC are the only copy. Rebuild the cluster, recreate the app
  database and roles, then load a dump into it. `restore-backup.sh` only restores
  into a *new* database on a healthy cluster; it is not a disaster-recovery
  procedure by itself.

## Sharp edges

- The real `PGDATA` is `/var/lib/pgsql/data/userdata`; the PVC mounts
  `/var/lib/pgsql/data`.
- Local connections (socket, `127.0.0.1`) are `trust`: from inside the pod no
  password is needed. Remote connections require the password.
- `oc apply` prints `configured` for the StatefulSet on every run even when
  nothing changed (the `volumeClaimTemplates` status); check real idempotency with
  the `resourceVersion`, not with that word.
- `oc rollout status` does not work with `updateStrategy: OnDelete`; watch the
  pods instead.
