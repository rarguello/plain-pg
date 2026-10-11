# Reads and scaling

## The four Services

| Service | Type | Selects | Use it for |
|---|---|---|---|
| `postgresql-hl` | Headless | every DB pod | per-pod DNS (used by replication) |
| `postgresql-rw` | ClusterIP | the primary | writes and read-after-write |
| `postgresql-r` | ClusterIP | every Ready instance | read scaling (load-balanced) |
| `postgresql-ro` | ClusterIP | one replica, by pod name | reads without touching the primary |

`postgresql-r` needs no maintenance: it selects all DB pods, so after a failover
or a scale-up it already points at the right set. `-rw`/`-ro` select by pod name
and are repointed by the failover scripts; `-ro` pins exactly **one** replica, so
extra replicas (from the HPA or a manual scale) are reachable only through `-r`.

`postgresql-r` balances **per TCP connection**, not per query: many short
connections spread over the Ready pods, one long-lived connection stays on one
instance. Do not send writes to `-r` (they would land on a random instance). Every
instance answers from the same WAL stream; a replica can be behind by the current
replication lag.

## Autoscaling the read fleet (HPA)

`components/read-scaling` adds an HPA that scales the StatefulSet on CPU
(request `100m`, target 70%, 2 to 5 pods). A new replica starts serving `-r` as
soon as it is Ready, with no Service change.

```bash
./scripts/deploy.sh manifests/overlays/lab-autoscale   # lab + HPA
./scripts/read-load.sh 180 12                          # 12 readers, 3 minutes
oc -n plain-pg get hpa postgresql-read
```

Measured in the lab (`t22`, `t23`): 40 connections were split 20/20 between two
instances, and 12 `pgbench` readers grew the fleet to 3 pods with the new replica
serving reads on its own.

## Caveats

| Condition | Consequence / action |
|---|---|
| The HPA scales down by removing the highest ordinals | only `postgresql-0`/`-1` can be primary; higher ordinals are read-only and disposable |
| An HPA owns `replicas` | do not scale by hand; `reseed-replica.sh` refuses while the HPA exists |
| Scale-up is not instant | each new replica does a full `pg_basebackup`, costing I/O on the primary (`maxReplicas: 5`) |
| Scale-down leaves the removed PVC orphaned | delete it: `oc -n plain-pg delete pvc pgdata-postgresql-N` |
| The primary is part of `-r` | it also serves some reads, so reads are not fully offloaded |
