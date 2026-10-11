# Tests

The suite runs **against a real cluster** (there are no mocks). Each test prints
`[PASS]`/`[FAIL]` per check and returns an exit code.

## How to run them

```bash
./tests/run-all.sh              # all (includes destructive: failover, teardown)
./tests/run-all.sh rapido       # only the non-destructive
./tests/run-all.sh t03 t04      # specific tests
```

The destructive ones (t07, t08, t11, t13, t15, t16, t17, t23) change the state
of the cluster, but **leave the system consistent when done**. t11 deletes the
PVCs and redeploys from scratch. t23 is slow: it waits for real HPA decisions.

## What each test covers

| Test | Covers |
|---|---|
| `t01_deploy` | Objects, PVCs, ready pods, UBI + PG18 image by digest |
| `t02_roles` | Who is primary/replica and their consistency on disk (`standby.signal`, `primary_conninfo`) |
| `t03_replication` | Streaming, lag 0, write→read between pods, replica read-only |
| `t04_services` | Endpoints of `-rw`/`-ro`/`-hl`, DNS and connection through the Services |
| `t05_config` | `wal_level`, `max_wal_senders`, `hot_standby`, `pg_hba`, replication user, app database and user |
| `t06_persistence` | Restarting the replica does not re-seed; restarting the primary does not lose data; replication resumes |
| `t07_failover_manual` | Full manual failover **and failback**, with data and Services verification |
| `t08_failover_auto` | The CronJob detects the unreachable primary and promotes; then restores |
| `t09_idempotency` | Re-applying does not change objects (resourceVersion), stable render, re-runnable `deploy.sh` |
| `t10_security` | Non-root, PodSecurity `restricted`, minimal RBAC, no secrets in git |
| `t11_teardown` | Teardown deletes everything and the redeploy ends up healthy |
| `t12_backup` | Valid manual backup and **verified restore** into a new database |
| `t13_scaling` | Scale to 3 replicas (it seeds and replicates) and back to 2 |
| `t14_integrity` | 5000 rows: identical checksum on primary and replica, lag 0 |
| `t15_reseed` | `reseed-replica.sh` recreates the PVC and seeds again |
| `t16_failover_load` | Failover with an active writer: data confirmed **before** the failover survives, the loss is bounded by the asynchronous window, and when done there is a single primary |
| `t17_auto_off` | `AUTO_FAILOVER=false` does **not** trigger failover |
| `t18_image` | The pinned digest matches the registry and the pods |
| `t19_selectors` | Regression: auxiliary pods do not collide with the Services selectors |
| `t20_full_restart` | After a failover, recreating **both** pods at once leaves the correct roles (no `Parallel` deadlock) |
| `t21_pg_security` | The app user is not superuser; the replica rejects DDL; from another pod the password is required |
| `t22_read_balancing` | `postgresql-r` selects every instance, spreads connections over all of them (none starved) and all return the same data |
| `t23_hpa` | Under read load the HPA grows the fleet, the new replica joins `postgresql-r` by itself and serves reads; then it restores the initial state |

## Requirements

- `oc` (or `kubectl`) logged in, with permission to create namespaces.
- `skopeo` and `~/.pull-secret.json` for `t18` (if not present, that test is skipped).
- Default StorageClass with `WaitForFirstConsumer` (so the backup PVC binds on
  first use).

## Static validation (without a cluster)

Before running anything against a cluster, the syntax of the scripts embedded in
the ConfigMaps and the kustomize render can be validated:

```bash
oc kustomize manifests/overlays/lab > /tmp/lab.yaml
oc kustomize manifests/overlays/lab-manual > /tmp/lab-manual.yaml
tools/check-scripts.py /tmp/lab.yaml /tmp/lab-manual.yaml
shellcheck -S warning scripts/*.sh tests/*.sh
```

That is what the CI (`.github/workflows/lint.yml`) runs on every push.

## Results

Last full run in the lab (OpenShift 4.21, SNO
`sno.virt.daytwo.dev`): **21/21 tests, 214 checks, 0 failures, ~15 min.**

| Test | PASS |
|---|---|
| t01 deployment | 29 |
| t02 roles | 11 |
| t03 replication | 7 |
| t04 services | 8 |
| t05 config | 13 |
| t06 persistence | 11 |
| t07 manual failover (round trip) | 18 |
| t08 automatic failover | 12 |
| t09 idempotency | 4 |
| t10 security | 16 |
| t11 teardown and redeploy | 11 |
| t12 backups and restore | 11 |
| t13 scaling | 8 |
| t14 integrity | 4 |
| t15 re-seed | 7 |
| t16 failover under load | 9 |
| t17 auto-failover disabled | 4 |
| t18 image and digest | 7 |
| t19 selectors (regression) | 8 |
| t20 full restart after failover | 9 |
| t21 PostgreSQL security | 7 |

Full output: [`evidence/2026-10-11-suite-completa.txt`](evidence/2026-10-11-suite-completa.txt).
