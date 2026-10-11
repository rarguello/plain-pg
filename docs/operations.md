# Operations

## Deploy

```bash
./scripts/deploy.sh                            # full (with automatic failover)
./scripts/deploy.sh manifests/overlays/lab-manual   # manual failover only
```

`deploy.sh` applies the overlay with Kustomize, generates the Secret (with random
passwords, outside git) and waits for the pods to be ready. It is idempotent.

## Verify

```bash
./scripts/verify-replication.sh
```

It does, in order: checks the roles, shows `pg_stat_replication`, verifies the
lag, and writes a row on the primary to read it from the replica.

By hand:

```bash
oc -n postgresql-lab get pods,pvc,svc
oc -n postgresql-lab exec postgresql-0 -- psql -U postgres -c 'SELECT * FROM pg_stat_replication;'
oc -n postgresql-lab exec postgresql-1 -- psql -U postgres -c 'SELECT pg_is_in_recovery();'   # t = replica
```

## Connect

The credentials are left in `secrets/postgresql-credentials.env` (not versioned).

```bash
NS=postgresql-lab
# app user (read/write)
oc -n $NS exec -it postgresql-0 -- psql -h postgresql-rw -U app -d appdb
# app user (read-only)
oc -n $NS exec -it postgresql-1 -- psql -h postgresql-ro -U app -d appdb
# superuser
oc -n $NS exec -it postgresql-0 -- psql -h 127.0.0.1 -U postgres
```

## Frequent tasks

```bash
# Logs
oc -n postgresql-lab logs -f postgresql-0
oc -n postgresql-lab logs -f postgresql-1

# Restart the replica (no impact on the app)
oc -n postgresql-lab delete pod postgresql-1        # recreated and re-attached

# Restart the primary (brief outage)
oc -n postgresql-lab delete pod postgresql-0

# Measure the replica lag
oc -n postgresql-lab exec postgresql-0 -- psql -U postgres -tAc \
  "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) FROM pg_stat_replication;"

# Add a replica (2 -> 3 pods)
oc -n postgresql-lab scale statefulset postgresql --replicas=3

# Back to 2 (the PVC of the removed pod is left orphaned; delete it if you do not want it)
oc -n postgresql-lab scale statefulset postgresql --replicas=2
oc -n postgresql-lab delete pvc pgdata-postgresql-2

# Re-seed a broken replica (copies it again from the primary)
./scripts/reseed-replica.sh postgresql-1
```

## If the replica fell too far behind

With asynchronous replication and no slots, the primary can recycle WAL the
replica needed (warning in the logs: `requested WAL segment … has already been
removed`). It is fixed by re-seeding:

```bash
./scripts/reseed-replica.sh postgresql-1
```

## Node maintenance

```bash
oc adm drain <node> --ignore-daemonsets --delete-emptydir-data
```

The primary pod is rescheduled (outage of seconds to minutes); the replica
re-attaches on its own when the primary returns.

## Notes

- The StatefulSet uses `updateStrategy: OnDelete`: changing the template restarts
  nothing. To apply a change, delete the pods by hand (`postgresql-1` first, if you
  want zero downtime).
- An `oc apply` of the manifests does **not** touch the Secret: it is managed
  with `scripts/generate-secret.sh`.
