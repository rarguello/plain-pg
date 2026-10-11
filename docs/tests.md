# Tests

The suite runs against a real cluster; there are no mocks. Each test prints
`[PASS]`/`[FAIL]` per check and returns an exit code.

```bash
./tests/run-all.sh              # all (destructive: failover, teardown)
./tests/run-all.sh quick        # non-destructive subset
./tests/run-all.sh t03 t04      # specific tests
```

## Coverage

Coverage. Last full run against a real cluster: **23/23 tests · 233 checks · 0
failures** (transcript in [Evidence](#evidence)).

| Test | What it proves | Checks | Result |
|---|---|---:|---|
| `t01_deploy` | Installs from scratch and both pods come up on the pinned UBI image | 29 | PASS |
| `t02_roles` | Exactly one primary and one hot standby, consistent on disk | 11 | PASS |
| `t03_replication` | Writes replicate to the standby; the standby is read-only | 7 | PASS |
| `t04_services` | Each Service routes to the right pods; per-pod DNS resolves | 11 | PASS |
| `t05_config` | Replication settings, users and the app database are correct | 13 | PASS |
| `t06_persistence` | Restarting either pod keeps the data and resumes replication | 11 | PASS |
| `t07_failover_manual` | A manual failover and failback move the role, the Services and the data | 18 | PASS |
| `t08_failover_auto` | The CronJob detects a dead primary and promotes a replica on its own | 12 | PASS |
| `t09_idempotency` | Re-applying the manifests changes no object | 4 | PASS |
| `t10_security` | Runs non-root, PodSecurity `restricted`, minimal RBAC, no secrets in git | 16 | PASS |
| `t11_teardown` | Teardown removes everything and a redeploy comes back healthy | 11 | PASS |
| `t12_backup` | A backup restores into a new database and the data checks out | 11 | PASS |
| `t13_scaling` | A new replica seeds itself from the primary; scaling back is clean | 9 | PASS |
| `t14_integrity` | 5000 rows are byte-identical on both nodes (checksum, lag 0) | 4 | PASS |
| `t15_reseed` | A broken replica is re-seeded from scratch and replicates again | 7 | PASS |
| `t16_failover_load` | Failover under active writes: existing rows survive, loss is only a suffix | 9 | PASS |
| `t17_auto_off` | `AUTO_FAILOVER=false` really disables automatic failover | 4 | PASS |
| `t18_image` | The pinned digest matches the registry and the running pods | 7 | PASS |
| `t19_selectors` | Auxiliary pods do not appear in the database Services | 8 | PASS |
| `t20_full_restart` | Both pods restart after a failover and keep the correct roles | 9 | PASS |
| `t21_pg_security` | The app user cannot do DDL/superuser work; remote access needs the password | 7 | PASS |
| `t22_read_balancing` | Reads through `-r` spread over all instances and return the same data | 4 | PASS |
| `t23_hpa` | Under load the HPA grows the fleet and the new replica serves reads | 11 | PASS |

Destructive tests (`t07`, `t08`, `t11`, `t13`, `t15`, `t16`, `t17`, `t23`) change
the cluster but leave it consistent. `t11` deletes the PVCs and redeploys from
scratch. `t23` waits for real HPA decisions and only runs from a fresh two-pod lab
with `postgresql-0` as primary and no HPA; otherwise it **skips**. Tests that need
`skopeo` and a pull secret (`t18`) also skip when it is missing. A `SKIP` is not a
pass — read the summary, not just the exit code. `t19` covers the two CronJob pod
templates, not every Job the scripts create.

## Requirements and static checks

- `oc` logged in with permission to create namespaces; `skopeo` and a pull secret
  for `t18`; a default StorageClass with `WaitForFirstConsumer`.
- `run-all.sh` deploys (or re-applies) the lab first with `scripts/deploy.sh`, so
  the suite works from scratch. That script needs `oc` and, when the lab already
  exists, Python with PyYAML, and it generates a throwaway
  `postgresql-credentials` Secret from gitignored `secrets/` (a real deploy
  creates it by hand; see `operations.md`).
- Without a cluster, `make lint` runs shellcheck, renders the three overlays, and
  validates the embedded scripts (`tools/check-scripts.py`) and the AGENTS.md hard
  rules — pinned UBI image, no operators, namespace, auxiliary-pod labels,
  PodSecurity — via `tools/check-policies.py`. CI (`.github/workflows/ci.yml`)
  adds kubeconform, yamllint, markdownlint, codespell, lychee, actionlint and
  gitleaks.

## Evidence

Raw output of full-suite runs:
[`evidence/2026-10-11-full-suite.txt`](evidence/2026-10-11-full-suite.txt).
The per-test check counts are in that transcript; the summary at the end is
authoritative. It is historical output — rerun the suite after code changes.
