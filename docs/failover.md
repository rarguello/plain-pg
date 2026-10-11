# Failover

The "primary" is the pod named by the `PRIMARY_POD` key of the `postgresql-role`
ConfigMap. Promoting a replica is changing that value and recreating the pods.

## Manual (the supported path)

```bash
./scripts/failover-manual.sh              # promotes the first replica
./scripts/failover-manual.sh postgresql-1   # explicit candidate
```

The script does, in this order:

0. Disables automatic failover for the duration of the operation (so the
   CronJob does not interfere) and re-enables it when done.
1. `PRIMARY_POD=<candidate>` in the ConfigMap.
2. Repoints the Services: `-rw` → candidate, `-ro` → ex-primary.
3. **Fencing of the ex-primary**: deletes it and waits to confirm that the pod
   object changed UID (or disappeared). If it cannot confirm, it **reverts** the
   ConfigMap and the Services and does not promote.
4. Recreates the candidate pod: on startup it sees that it is the primary,
   deletes `standby.signal` and **promotes**.
5. Waits to confirm. If it does not promote, it does **not** revert to the
   ex-primary (already isolated): it leaves the declared state on the candidate
   and fails hard so a person intervenes.

Fencing goes **before** promoting: that way there are never two primaries at
once. The ex-primary, when recreated, re-seeds itself from the new primary.

### By hand (equivalent)

Same order as the script: **fencing before promoting**. If in step 3 it is not
confirmed that the ex-primary finished, **it is not promoted**.

```bash
NS=postgresql-lab
OLD=postgresql-0     # current primary
NEW=postgresql-1     # candidate

# 0. Disable automatic failover for the duration of the operation
oc -n $NS patch configmap postgresql-role --type merge -p '{"data":{"AUTO_FAILOVER":"false"}}'

# 1. Declare the candidate as primary
oc -n $NS patch configmap postgresql-role --type merge -p "{\"data\":{\"PRIMARY_POD\":\"$NEW\"}}"

# 2. Repoint the Services
oc -n $NS patch svc postgresql-rw -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$NEW\"}}}"
oc -n $NS patch svc postgresql-ro -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$OLD\"}}}"

# 3. FENCING: delete the ex-primary and CONFIRM that it finished
oc -n $NS get pod $OLD -o jsonpath='{.metadata.uid}'; echo   # note the UID
oc -n $NS delete pod $OLD
#   wait and query the UID again: it must be DIFFERENT, or the pod must not exist.
#   If the UID does not change, DO NOT continue: the previous primary is still alive.

# 4. Promote the candidate
oc -n $NS delete pod $NEW
oc -n $NS exec $NEW -- psql -U postgres -tAc 'SELECT pg_is_in_recovery();'  # must return f

# 5. Re-enable the automatic one
oc -n $NS patch configmap postgresql-role --type merge -p '{"data":{"AUTO_FAILOVER":"true"}}'
```

It is easy to make a mistake by hand (especially in step 3). The
`failover-manual.sh` script does exactly this, with verification of each step and
rollback if something fails: use it unless you have no other option.

## Automatic (optional, *best-effort*)

`components/failover-automatico` adds a CronJob that runs every minute:

1. Reads the declared role **fresh from the API** (not from environment variables)
   and if the primary responds (`pg_is_in_recovery()` = `f`), it does nothing.
2. If it does not respond, it waits `FAILOVER_GRACE_SECONDS` (default 120 s) in
   case it is transient.
3. Picks a healthy replica (`pg_is_in_recovery()` = `t`).
4. Declares the candidate as primary and repoints the Services.
5. **Fencing**: deletes the ex-primary and waits to confirm that its pod changed
   UID (or disappeared). If it cannot confirm, it **reverts** everything and does
   not promote.
6. Recreates the candidate pod to promote it and confirms. If it does not promote,
   it does not revert (the ex-primary is already isolated): it fails hard.

It is configured in the `postgresql-role` ConfigMap:

```bash
oc -n postgresql-lab patch configmap postgresql-role --type merge \
  -p '{"data":{"AUTO_FAILOVER":"true","FAILOVER_GRACE_SECONDS":"120"}}'
```

`AUTO_FAILOVER=false` disables it without deleting the CronJob (useful during
maintenance). The `lab-manual` overlay does not include it.

### What it does NOT do (read before production)

- **Fencing is not STONITH: it does not guarantee the old process is dead.** It
  relies on Kubernetes confirming pod termination (the object disappears or
  changes UID). If the **node** of the ex-primary is partitioned from the API
  server, the pod object may disappear when the grace period expires even though
  the container is still running: fencing would give a false positive and two
  primaries could remain (split-brain).

  **Practical consequence:** while there is no external fencing of the node,
  automatic failover is acceptable for a lab or for scenarios where the failure
  is of the pod (not the node). For production with a real guarantee:
  - enable node-level isolation (for example `MachineHealthCheck` +
    `fence_ack`, or the infrastructure provider's mechanism) before trusting
    automatic failover; or
  - leave `AUTO_FAILOVER=false` and operate manual failover, where a person can
    verify that the previous node/primary is really out.

  The repo does **not** claim physical isolation of the previous primary: it
  only verifies the pod.
- **Replication is asynchronous**: a failover can lose the last transactions that
  did not get replicated. If that is not acceptable, enable synchronous
  replication (see below): the commit waits for the replica, at the cost that if
  the replica goes down, writes block.
- **Detection is by timeout**, not by consensus: with a short `GRACE` and a slow
  primary, it may promote too much. A conservative value (120–300 s) is
  sensible.
- **It does not retry beyond what is described.** If the promotion fails, the
  declared state on the candidate remains and a person must intervene.
- **A failover to a high ordinal is fragile with an HPA.** If the new primary is
  `postgresql-2` or higher and the read-scaling HPA later scales the fleet down,
  it removes the highest ordinals — which can be the primary. The scripts warn
  when this happens; fail back to `postgresql-0` before letting the fleet
  shrink. See [scaling.md](scaling.md).

### Synchronous replication (failover without loss)

On the primary:

```sql
ALTER SYSTEM SET synchronous_standby_names = 'walreceiver';
SELECT pg_reload_conf();
```

With `synchronous_commit = on` (default), each commit waits for the replica. A
failover loses no confirmed data. **Trade-off:** if the replica goes down, writes
block until it returns (or until the name is removed from the list).
