# Reads and scaling

## The four Services

| Service | Type | Selects | Use it for |
|---|---|---|---|
| `postgresql-hl` | Headless | every DB pod | per-pod DNS (used by replication) |
| `postgresql-rw` | ClusterIP | the primary only | writes and read-after-write |
| `postgresql-r` | ClusterIP | every Ready instance | read scaling (load-balanced) |
| `postgresql-ro` | ClusterIP | the replica only | reads without touching the primary |

`postgresql-r` needs no maintenance: it selects all DB pods, so after a failover
or a scale-up it already points at the right set. `postgresql-rw` and `postgresql-ro`
select by pod name and are repointed by the failover scripts.

## How `postgresql-r` balances

A ClusterIP Service load-balances **per TCP connection**, not per query. Every
new connection is spread over the Ready pods; a long-lived connection stays on
one instance. So:

- for many short connections (typical app pools opening connections), the load
  spreads;
- for a single long-lived connection, everything goes to one instance.

Every instance in `postgresql-r` answers with the same data: the replicas are hot
standbys of the same WAL stream, so a read served by a replica is a read of the
same database (with sub-second lag).

Do **not** send writes to `postgresql-r`: they would land on a random instance and
fail on a replica. Writes go to `postgresql-rw`.

## Autoscaling the read fleet (HPA)

The optional `read-scaling` component adds an HPA that scales the StatefulSet
with CPU. It is a natural pair with `postgresql-r`: a new replica starts receiving
read traffic as soon as it is Ready, with no Service change.

```bash
./scripts/deploy.sh manifests/overlays/lab-autoscale   # lab + HPA
./scripts/read-load.sh 180 12                          # 12 readers, 3 minutes
oc -n postgresql-lab get hpa postgresql-read
```

The HPA measures CPU against the pods' **request** (`100m` in the StatefulSet),
targets 70%, and can go from 2 to 5 pods. Scale-up reacts in under a minute;
scale-down waits 5 minutes, because seeding a replica is expensive.

Measured in the lab (see `tests/t22_read_balancing.sh` and `t23_hpa.sh`):

- 40 connections through `postgresql-r` were split **20/20** between the two
  instances;
- under 12 `pgbench` read clients, the HPA grew the fleet from 2 to 3 pods and
  the new replica started serving reads on its own.

### Caveats

- **The primary must be the lowest ordinal (0 or 1).** The HPA scales *down* by
  removing the highest ordinals, so if a failover ever promotes `postgresql-2`
  or higher, a later scale-down can remove the pod that is the primary. The
  failover scripts warn when that happens: fail back to `postgresql-0`
  (`./scripts/failover-manual.sh postgresql-0`) before letting the fleet shrink.
- While an HPA owns `replicas`, do **not** scale the StatefulSet by hand: the
  HPA will override you. `reseed-replica.sh` refuses to run in that case (it has
  to scale down to release the PVC).
- Scaling up is not instant: each new replica does a full `pg_basebackup` from
  the primary, which costs I/O on the primary. `maxReplicas: 5` is a deliberate
  bound.
- Scaling down leaves the removed replica's PVC orphaned. Delete it:
  `oc -n postgresql-lab delete pvc pgdata-postgresql-N`.
- CPU is a blunt signal for a database. If you want to scale on queries per
  second or connection count, use a custom/external metric; the mechanism is the
  same HPA.
- The primary is part of `postgresql-r`, so it also serves some reads. That is
  fine for reads, but it does not offload the primary completely.
