# Failover

The primary is the pod named by `PRIMARY_POD` in the `postgresql-role` ConfigMap.
Promoting a replica means changing that value and recreating pods.

## Manual (the supported path)

```bash
./scripts/failover-manual.sh                # promotes the first replica
./scripts/failover-manual.sh postgresql-1   # explicit candidate
```

The script, in order:

1. Disables automatic failover for the duration of the operation.
2. Sets `PRIMARY_POD=<candidate>` (with `resourceVersion` control) and repoints
   `-rw` → candidate, `-ro` → ex-primary.
3. **Fences the ex-primary**: deletes it and waits to confirm that the pod
   disappeared or changed UID. If the delete is rejected and the pod is still
   intact, it reverts the ConfigMap and the Services and does not promote. If it
   cannot be sure nothing changed (the pod is no longer intact, or its termination
   cannot be confirmed), it does **not** revert: it fails hard for intervention.
4. Recreates the candidate, which sees the new role and promotes itself.
5. Waits to confirm. If the candidate does not promote, it is **not** reverted
   (the ex-primary is already isolated): the declared state stays on the candidate
   and the script fails hard so a person intervenes.

Fencing completes before the candidate is recreated. Only `postgresql-0` and
`postgresql-1` can be promoted; higher ordinals serve reads only, because the read
HPA removes the highest ordinals on scale-down.

## Automatic (optional, best-effort)

`components/automatic-failover` adds a CronJob that runs every minute:

1. Reads the role fresh from the API. If the primary answers
   (`pg_is_in_recovery()` = `f`), it does nothing.
2. If it does not answer, waits `FAILOVER_GRACE_SECONDS` (default 120 s).
3. Picks a healthy replica among ordinals 0 and 1.
4. Re-reads the ConfigMap and aborts if the role changed or auto-failover was
   disabled during the grace period, then declares the candidate primary (with
   `resourceVersion` control) and repoints the Services.
5. Fences the ex-primary: it reverts and does not promote only when it is certain
   nothing changed; otherwise it leaves the new role and fails hard.
6. Recreates the candidate to promote it and confirms. If it does not promote, it
   does not revert: it fails hard.

Enabled in the `postgresql-role` ConfigMap:

```bash
oc -n postgresql-lab patch configmap postgresql-role --type merge \
  -p '{"data":{"AUTO_FAILOVER":"true","FAILOVER_GRACE_SECONDS":"120"}}'
```

`AUTO_FAILOVER=false` disables it without deleting the CronJob. The `lab-manual`
overlay does not include it.

## Limits

Read these before relying on automatic failover.

| Condition | Consequence | Action |
|---|---|---|
| The **node** of the primary is partitioned from the API server | pod-level fencing can declare a primary dead whose process is still running; two primaries may remain (split-brain) | enable node-level isolation (for example `MachineHealthCheck` + a fence agent) before trusting automatic failover, or keep it disabled |
| Replication is asynchronous | a failover can lose the last unreplicated transactions; the loss is not bounded by the design | accept it, or enable synchronous replication (out of scope here) |
| Detection is by timeout, not consensus | a slow primary can be declared down too early | keep `FAILOVER_GRACE_SECONDS` conservative (120–300 s) |
| A pod restarts between declaring the new role and finishing fencing | the candidate can promote, or the ex-primary can wipe and re-seed its PGDATA, before isolation is confirmed | not guarded: a spontaneous restart can hit this window, so verify a single primary after any failover |
| Promotion does not check the replay position | a reachable but stale standby can be promoted | fail over by hand when you need a bounded loss |
| The promotion fails | the declared state stays on the candidate; the ex-primary is isolated | finish it (`oc -n postgresql-lab delete pod <candidate>`) or roll back explicitly |

Fencing is **not STONITH**: it verifies the Kubernetes pod object (it disappeared
or changed UID), not that the PostgreSQL process died. There is no external
fencing of the node, so this is a lab-grade guarantee.
