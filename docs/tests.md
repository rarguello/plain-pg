# Tests

The suite runs against a real cluster; there are no mocks. Each test prints
`[PASS]`/`[FAIL]` per check and returns an exit code.

```bash
./tests/run-all.sh              # all (destructive: failover, teardown)
./tests/run-all.sh quick        # non-destructive subset
./tests/run-all.sh t03 t04      # specific tests
```

## Coverage

Last full run against a real cluster: **30/30 tests · 287 checks · 0 failures**
(transcript in [Evidence](#evidence)).

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
| `t24_deploy_recreate` | `deploy.sh` recreates a deleted StatefulSet with the right replica count | 10 | PASS |
| `t25_metrics` | The `postgres_exporter` reaches the database and serves metrics | 6 | PASS |
| `t26_tls` | The service-ca certificate makes PostgreSQL require TLS and replication uses it | 7 | PASS |
| `t27_tls_byo` | A bring-your-own certificate (a tiny openssl PKI) serves TLS with `verify-full` | 6 | PASS |
| `t28_external` | A NodePort on `-rw` reaches the primary, and the policy still blocks outsiders | 8 | PASS |
| `t29_failover_guard` | A declared candidate does not promote while `FAILOVER_GUARD` is set | 7 | PASS |
| `t30_dr_drill` | With both PGDATA PVCs lost, the cluster is rebuilt and the dump is loaded back | 10 | PASS |

Destructive tests (`t07`, `t08`, `t11`, `t13`, `t15`, `t16`, `t17`, `t23`, `t24`,
`t26`, `t27`, `t28`, `t29`, `t30`) change the cluster but leave it consistent. `t11` deletes the
PVCs and redeploys from scratch; `t24` deletes the StatefulSet and checks that
`deploy.sh` recreates it with the right replica count; `t26`/`t27` mount a TLS
certificate and recreate the pods; `t28` makes `postgresql-rw` a NodePort and
restores it; `t29` declares a candidate with the guard set and restarts it; `t30`
deletes the StatefulSet and both PGDATA PVCs and rebuilds from a dump.
`t23` waits for real HPA decisions and only runs from a fresh two-pod
lab with `postgresql-0` as primary and no HPA; `t25` needs the
`monitoring.coreos.com` CRDs and `t26` the service-ca controller, and both
**skip** without them; `t27` skips without `openssl`. Tests that need `skopeo` and
a pull secret (`t18`) also skip when it is missing. A `SKIP` is not a pass — read
the summary, not just the exit code. `t19` covers the two CronJob pod templates,
not every Job the scripts create.

## Requirements and static checks

- `oc` logged in with permission to create namespaces; `skopeo` and a pull secret
  for `t18`; `openssl` for `t27`; a default StorageClass with
  `WaitForFirstConsumer`; the `monitoring.coreos.com` CRDs for `t25` and the
  service-ca controller for `t26` (both skip without them).
- `run-all.sh` deploys (or re-applies) the lab first with `scripts/deploy.sh`, so
  the suite works from scratch. That script needs `oc` and, when the lab already
  exists, Python with PyYAML, and it generates a throwaway
  `postgresql-credentials` Secret from gitignored `secrets/` (a real deploy
  creates it by hand; see `operations.md`).
- Without a cluster, `make lint` runs shellcheck, renders the seven overlays, and
  validates the embedded scripts (`tools/check-scripts.py`) and the AGENTS.md hard
  rules — pinned UBI image, no operators, namespace, auxiliary-pod labels,
  PodSecurity — via `tools/check-policies.py`. CI (`.github/workflows/ci.yml`)
  adds kubeconform, yamllint, markdownlint, codespell, lychee, actionlint and
  gitleaks.

## Running on MicroShift (MINC)

CI runs the suite against a throwaway MicroShift cluster, created inside the
GitHub runner with [MINC](https://github.com/minc-org/minc)
(`.github/workflows/cluster.yml`, manual + nightly): it creates the cluster,
prepares it, runs the tests and uploads the transcript as an artifact. The same
thing locally:

```bash
minc create && minc generate-kubeconfig
PULL_SECRET=~/.pull-secret.json ./scripts/minc-up.sh   # storage + pull secret
./tests/run-all.sh quick
```

MicroShift ships no StorageClass and does not wire a pull secret, so
`minc-up.sh` adds a local-path provisioner and makes its StorageClass the
default, plus the Red Hat pull secret on the namespace's default
ServiceAccount. The tests read the expected StorageClass from `STORAGE_CLASS`
(default `lvms-vg1`, the lab's), so the nightly sets `STORAGE_CLASS=local-path`.

The nightly runs the whole `quick` subset (14 tests, ~70 s). The destructive tests
(failover, teardown, HPA) and the optional add-ons stay on a real lab. The workflow
reads the pull secret from the `RH_PULL_SECRET` repository secret.

## Evidence

Raw output of full-suite runs:
[`evidence/2026-10-16-full-suite.txt`](evidence/2026-10-16-full-suite.txt).
The per-test check counts are in that transcript; the summary at the end is
authoritative. It is historical output — rerun the suite after code changes.
