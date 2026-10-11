# Scenarios: what happens if…

This matrix summarizes the expected behavior. The test suite exercises almost
all of these cases (`docs/tests.md`).

| Scenario | With manual failover | With automatic failover | Action |
|---|---|---|---|
| The PostgreSQL process on the primary dies | The pod restarts and comes back as primary. Outage of seconds. | Same, **if** it comes back before `GRACE`. If it takes longer, it promotes a replica. | None if it comes back on its own. |
| The primary pod is deleted | K8s recreates it with the same PVC; it comes back as primary. | Same as above (the deletion is not a long outage). | None. |
| The replica pod dies | K8s recreates it; it re-attaches to the primary **without** re-seeding (it keeps the PVC). | Same. | None. |
| The primary becomes unreachable (network) | The app cannot write. It must be promoted by hand. | After `GRACE`, it isolates the ex-primary (verifiable fencing), promotes the replica and repoints the Services. | Verify that there are not two primaries. |
| The **node** of the primary is split from the API server | The pod stays alive, but the API server may terminate it when the grace period expires. | Fencing may give a false positive (it is not STONITH). | Check the node before reincorporating it. |
| The replica fell behind and the primary recycled WAL | Log: `requested WAL segment … has already been removed`. Replication broken. | Same (failover does not fix it). | `./scripts/reseed-replica.sh postgresql-1` |
| The primary PVC is corrupted | Promote the replica; the ex-primary re-seeds from scratch. | Same, automatic. | Verify the data is complete; restore a backup if something is missing. |
| The replica PVC is deleted | On recreation, `PGDATA` empty → full `pg_basebackup`. | Same. | None. |
| The data PVC disk fills up | PostgreSQL goes read-only and stops accepting writes. | The primary still "responds", so there is **no** failover. | Free space / re-seed. Backups live on another PVC. |
| The replication password is rotated | The Secret must be regenerated and the pods recreated. | Same. | `scripts/generate-secret.sh` + delete the pods. |
| `oc adm drain` of the primary node is run | The pod is rescheduled; the app has an outage. | Same. | None (multi-node clusters). |
| It is scaled to 3 pods | `postgresql-2` seeds from the primary and replicates. `-ro` does **not** include it. | Same. | Use the pod DNS or widen the `-ro` selector. |
| It is scaled from 3 to 2 | `postgresql-2` is removed; its PVC is left orphaned. | Same. | `oc delete pvc pgdata-postgresql-2` |
| An `oc apply` of the manifests | It does not restart the database (`OnDelete`). | Same. | Delete pods by hand to apply template changes. |
| The Secret is deleted | New pods do not start (`CreateContainerConfigError`). | The CronJob does not run either. | Regenerate the Secret. |
| The whole node is lost (SNO cluster) | Everything goes down; when the node returns, the pods start with their PVCs. | Same. | None. |

## Cases that need human intervention

- **The primary node partitioned from the API server**: fencing may give a false
  positive. Check that two primaries are not left before returning the
  ex-primary to service.
- **Loss of the primary and replica PVCs at the same time**: only the backup is
  left. `./scripts/restore-backup.sh`.
- **Data divergence after an asynchronous failover**: the ex-primary re-seeds and
  what was not replicated is lost. To avoid it, synchronous replication
  ([failover.md](failover.md)).
- **Failed promotion**: the declared state remains on the candidate and the
  ex-primary is isolated. Finish the promotion by hand
  (`oc -n postgresql-lab delete pod <candidate>`) or roll back explicitly.
