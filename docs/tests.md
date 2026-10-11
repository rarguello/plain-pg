# Tests

The suite runs against a real cluster; there are no mocks. Each test prints
`[PASS]`/`[FAIL]` per check and returns an exit code.

```bash
./tests/run-all.sh              # all (destructive: failover, teardown)
./tests/run-all.sh quick        # non-destructive subset
./tests/run-all.sh t03 t04      # specific tests
```

## Coverage

| Test | Covers |
|---|---|
| `t01_deploy` | Objects, PVCs, ready pods, UBI + PG18 image by digest |
| `t02_roles` | Who is primary/replica, and consistency on disk |
| `t03_replication` | Streaming, lag 0, write→read, replica is read-only |
| `t04_services` | Endpoints of `-rw`/`-ro`/`-hl`, DNS and connections |
| `t05_config` | `wal_level`, senders, `hot_standby`, `pg_hba`, users, database |
| `t06_persistence` | Restarts keep the data and resume replication |
| `t07_failover_manual` | Full manual failover and failback |
| `t08_failover_auto` | The CronJob promotes an unreachable primary |
| `t09_idempotency` | Re-applying changes no object (`resourceVersion`) |
| `t10_security` | Non-root, PodSecurity `restricted`, RBAC, no secrets in git |
| `t11_teardown` | Teardown deletes everything; the redeploy is healthy |
| `t12_backup` | Backup and verified restore into a new database |
| `t13_scaling` | Scale to 3 (the new replica seeds), back to 2 |
| `t14_integrity` | 5000 rows: identical checksum, lag 0 |
| `t15_reseed` | `reseed-replica.sh` recreates the PVC and seeds again |
| `t16_failover_load` | Preexisting rows survive; the observed loss is a suffix |
| `t17_auto_off` | `AUTO_FAILOVER=false` does not trigger a failover |
| `t18_image` | The pinned digest matches the registry and the pods |
| `t19_selectors` | Auxiliary pods do not collide with the Services |
| `t20_full_restart` | Recreating both pods after a failover keeps the roles |
| `t21_pg_security` | App user is not superuser; replica rejects DDL; remote auth |
| `t22_read_balancing` | `-r` selects every instance and spreads connections |
| `t23_hpa` | The HPA grows the fleet under load; the new replica serves reads |

Destructive tests (`t07`, `t08`, `t11`, `t13`, `t15`, `t16`, `t17`, `t23`) change
the cluster but leave it consistent. `t11` deletes the PVCs and redeploys from
scratch. `t23` waits for real HPA decisions and only runs from a fresh two-pod lab
with `postgresql-0` as primary and no HPA; otherwise it **skips**. Tests that need
`skopeo` and a pull secret (`t18`) also skip when it is missing. A `SKIP` is not a
pass — read the summary, not just the exit code.

## Requirements and static checks

- `oc` logged in with permission to create namespaces; `skopeo` and a pull secret
  for `t18`; a default StorageClass with `WaitForFirstConsumer`.
- The suite's `scripts/deploy.sh` generates a throwaway `postgresql-credentials`
  Secret from gitignored `secrets/` (a real deploy creates it by hand; see
  `operations.md`).
- Without a cluster: `oc kustomize` of the overlays plus
  `tools/check-scripts.py` validate the scripts embedded in the ConfigMaps, and
  `shellcheck -S warning scripts/*.sh tests/*.sh` lints the rest. CI
  (`.github/workflows/lint.yml`) runs all of that on every push.

## Evidence

Raw output of full-suite runs:
[`evidence/2026-10-11-full-suite.txt`](evidence/2026-10-11-full-suite.txt).
The per-test check counts are in that transcript; the summary at the end is
authoritative. It is historical output — rerun the suite after code changes.
