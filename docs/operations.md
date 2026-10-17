# Operations

Day-2 operations: deploy a profile, change the PostgreSQL image, credentials,
metrics, TLS, external access, verification and recovery.

## Contents

- [Deploy](#deploy): a fresh install, and what re-applying does
- [Overlays](#overlays): the profiles, and the components they combine
- [Deploy with your own values](#deploy-with-your-own-values): your namespace, StorageClass or image, without editing this repository
- [Changing the PostgreSQL image](#changing-the-postgresql-image): platform or version
- [Settings and pg_hba](#settings-and-pg_hba): your postgresql.conf settings and extra pg_hba rules
- [Single instance](#single-instance-no-replica): one pod, and the step to HA
- [Credentials](#credentials) · [Scripts](#scripts-test-tooling) · [Metrics](#metrics) · [TLS](#tls) · [External access](#external-access-nodeport)
- [Verify and connect](#verify-and-connect) · [Frequent tasks](#frequent-tasks) · [Recovery](#recovery) · [Sharp edges](#sharp-edges)

## Deploy

An install is manifests only: create the namespace and the credentials Secret by
hand, then apply. The primary runs `initdb` and the replica `pg_basebackup` on
startup, so there is nothing else to run.

```bash
oc apply -f manifests/base/namespace.yaml
# create the Secret first: the full command is under Credentials, below
oc apply -k manifests/overlays/ha
oc -n plain-pg get pods      # wait for 2/2 Ready
```

Re-applying the overlay on a live cluster **resets** `PRIMARY_POD`, the
`-rw`/`-ro` selectors and `spec.replicas`. It would revert a failover and fight
an HPA. To change something live, patch that object; to return to the initial primary,
`./scripts/failover-manual.sh postgresql-0`.

For manual failover only (no failover CronJob), apply
`manifests/overlays/ha-manual` instead.

### Overlays

`manifests/base` is the HA core (a primary and a hot standby) with no optional
feature; `manifests/components` holds the features; each overlay is a named
example that combines them.

| Overlay | Pods | Adds | Use it when |
|---|---:|---|---|
| `ha` | 2 | automatic failover (the CronJob) | default; `scripts/deploy.sh` applies it |
| `ha-manual` | 2 | none | you promote by hand only |
| `single` | 1 | none | you do not want a replica |
| `ha-metrics` | 2 | the `postgres_exporter` | Prometheus scrapes PostgreSQL |
| `ha-tls` | 2 | TLS, certificate from service-ca | clients must encrypt |
| `ha-tls-byo` | 2 | TLS, your own certificate | you have your own PKI |
| `ha-external` | 2 | a NodePort on `postgresql-rw` | clients outside the cluster |
| `ha-autoscale` | 2 | the read HPA | reads must scale |
| `single-tls` | 1 | TLS, certificate from service-ca | one pod, encrypted |

The components are meant to be combined, so your own mix needs no new overlay. A
kustomization of your own is enough:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: plain-pg
resources: [../../base]
components:
  - ../../components/single-instance
  - ../../components/metrics
  - ../../components/tls
  - ../../components/tls-service-ca
  - ../../components/image   # pins the PostgreSQL image; keep it LAST
```

Available components: `automatic-failover`, `single-instance`, `metrics`,
`read-scaling`, `tls`, `tls-service-ca`, `external-access`, and `image` (the one
place the PostgreSQL image is pinned; it goes last, because a component's
transformer only covers the resources accumulated before it).

`plain-pg` is only the example namespace (`manifests/base/namespace.yaml`). Do not
edit these manifests to deploy elsewhere: reference them from your own
kustomization and set `namespace:` there. Kustomize renames the Namespace object
too, labels included, as in
[Deploy with your own values](#deploy-with-your-own-values). The scripts under
`scripts/` are the test tooling and take `NAMESPACE`.

## Deploy with your own values

Nothing in this repository needs editing. Keep your own kustomization next to your
other manifests and reference this repository as a base. Both examples below are
complete: `my-postgres/kustomization.yaml` in your own repository.

The base ships the example namespace, with the PodSecurity labels the pods expect.
Setting `namespace:` renames it, labels included, so nothing lands in `plain-pg`.

### Example 1: your namespace and your StorageClass

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: my-pg

resources:
  # Pin a tag or a commit for reproducibility; `main` follows the repository.
  - github.com/rarguello/plain-pg//manifests/overlays/ha?ref=main

patches:
  # The deployment has two PVCs. No StorageClass is shipped on purpose: they use
  # the cluster default. This example gives the data a faster class than the
  # backups.
  - target: {kind: StatefulSet, name: postgresql}
    patch: |-
      - op: replace
        path: /spec/volumeClaimTemplates/0/spec/storageClassName
        value: fast-ssd
  - target: {kind: PersistentVolumeClaim, name: postgresql-backups}
    patch: |-
      - op: add
        path: /spec/storageClassName
        value: standard
```

```bash
oc apply -k my-postgres          # creates my-pg (with its labels) and the objects
oc -n my-pg create secret generic postgresql-credentials ...   # see Credentials
```

The pods wait for the Secret; they start as soon as it exists.

### Example 2: another PostgreSQL version

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: my-pg

resources:
  - github.com/rarguello/plain-pg//manifests/overlays/ha?ref=main

# The image is pinned in this repository. Match the real name: the base renames
# the logical one, so `name: postgresql` would match nothing here.
images:
  - name: registry.redhat.io/rhel10/postgresql-18
    newName: registry.redhat.io/rhel9/postgresql-16
    digest: sha256:791a6f14563178d1bbcd3515bc7dc80c1ae0788a829ff26551cdedbf8f50f0d2
```

The digest is the one you want to run:

```bash
skopeo inspect --authfile ~/.pull-secret.json \
  docker://registry.redhat.io/rhel9/postgresql-16 | jq -r .Digest
```

**A different major version does not reuse the data directory.** PostgreSQL
refuses to start on a PGDATA from another major, so delete the StatefulSet and the
`pgdata-*` PVCs before applying (the backups PVC is not affected), or deploy into
a fresh namespace. See [Changing the PostgreSQL image](#changing-the-postgresql-image)
for the same change made in this repository, and
[Supported images](supported-images.md) for what has been tested.

### Notes for both

- If you vendor this repository next to your kustomization instead of using the
  remote base, kustomize's file restrictions require
  `kustomize build --load-restrictor LoadRestrictionsNone . | oc apply -f -`.
- To choose every piece yourself (the base plus the components), see
  [Overlays](#overlays).

## Changing the PostgreSQL image

This section is for this repository. To override the image from an overlay of your
own, without editing anything here, see Example 2 in
[Deploy with your own values](#deploy-with-your-own-values).

In this repository the image is pinned in
`manifests/components/image/kustomization.yaml`:

```yaml
images:
  - name: postgresql                                   # the logical name used by the resources
    newName: registry.redhat.io/rhel10/postgresql-18
    digest: sha256:2e04d97c...
```

To move to another platform or major version:

1. Edit `newName` and `digest` in that file. For a new build of the same image,
   `./scripts/update-digest.sh --apply` updates the digest alone.

2. Delete the data. PostgreSQL refuses to start on a data directory from another
   major version, so the StatefulSet and the PGDATA PVCs must go. The backups PVC
   is not affected.

   ```bash
   oc -n plain-pg delete statefulset postgresql --wait=true
   oc -n plain-pg delete pvc pgdata-postgresql-0 pgdata-postgresql-1 --wait=true
   ```

3. Apply the overlay and wait for the pods:

   ```bash
   oc apply -k manifests/overlays/ha
   oc -n plain-pg get pods      # wait for 2/2 Ready
   ```

4. Verify:

   ```bash
   oc -n plain-pg exec postgresql-0 -- postgres --version
   oc -n plain-pg exec postgresql-0 -- printenv PLATFORM
   ./scripts/verify-replication.sh
   ```

`./scripts/test-image.sh rhel9/postgresql-16` performs steps 1 to 3 and then runs
the whole test suite against the new image. Which images have been tested, and
which one is supported, is in [supported-images.md](supported-images.md).

## Settings and pg_hba

`components/settings` (overlay `ha-settings`) applies your own `postgresql.conf`
settings and extra `pg_hba.conf` rules. It edits neither file in `PGDATA`:
`postgresql.conf` is never touched (the settings are pulled in from
`postgresql.auto.conf`), and the `pg_hba` rules are inserted as a marked block
before the image's catch-all rules, which is where they can take effect, because
`pg_hba.conf` is first match.

Edit the two ConfigMaps of the component:

```yaml
# postgresql-settings, key settings.conf
work_mem = '16MB'
log_min_duration_statement = '500ms'
```

```yaml
# postgresql-hba, key extra.conf. The image writes `host ... md5`, and
# PostgreSQL 18 deprecates md5: this replaces it for clients and replication.
host all         all  all  scram-sha-256
host replication all  all  scram-sha-256
```

`host` matches plaintext connections and `hostssl` only TLS ones: use `hostssl`
if the deployment requires TLS (the TLS rewrite only touches the image's own
catch-all lines).

Then apply the overlay and recreate the pods (`updateStrategy` is `OnDelete`).
Removing the component removes both on the next start. Write `hostssl` in your
rules if they must require TLS: the TLS rewrite only touches the image's catch-all
lines.

Two alternatives:

- The image already exposes a few settings as environment variables
  (`POSTGRESQL_SHARED_BUFFERS`, `POSTGRESQL_MAX_CONNECTIONS`,
  `POSTGRESQL_MAX_PREPARED_TRANSACTIONS`, `POSTGRESQL_EFFECTIVE_CACHE_SIZE`,
  `POSTGRESQL_LIBRARIES`, `POSTGRESQL_LOG_DESTINATION`). Set those in the
  StatefulSet instead: no component needed.
- `ALTER SYSTEM SET ...` also works (it writes `postgresql.auto.conf`), but it
  lives in the PVC and not in git.

## Single instance (no replica)

`overlays/single` is the same deployment with **one pod**: the same image
pinned by digest, non-root, probes, resources, NetworkPolicy, per-pod PVC and
`pg_dump` backups. It leaves out what only makes sense with a standby: the
automatic-failover CronJob (there is nothing to promote) and the `postgresql-ro`
Service (it pins a replica that does not exist; read through `postgresql-r`,
which selects the single instance).

```bash
oc apply -k manifests/overlays/single
oc -n plain-pg get pods                      # 1/1 Ready
```

**Going to HA is one command.** Scaling the StatefulSet up starts the new pod as
a hot standby by itself: it reads `PRIMARY_POD`, sees that it is not the primary,
and runs `pg_basebackup`.

```bash
oc -n plain-pg scale sts postgresql --replicas=2
```

Scaling back down removes the highest ordinal; the primary keeps running and its
data. What the scale alone does **not** give you is the `postgresql-ro` Service
and the failover CronJob. Apply `manifests/overlays/ha` for those (it also sets
`AUTO_FAILOVER=true`).

`oc apply` does not delete objects that the new overlay no longer defines, so
switching from HA down to the single profile needs the leftovers removed by hand:

```bash
oc apply -k manifests/overlays/single
oc -n plain-pg delete svc postgresql-ro cronjob postgresql-failover
```

With one pod there is **no HA**: a restart, an upgrade or a node failure is
downtime, and the dumps on `postgresql-backups` are the only recovery (see
[Recovery](#recovery)). `t31` runs this profile and the step to HA; TLS is
available here too, with `overlays/single-tls` (see [TLS](#tls), and `t32`).

## Credentials

`postgresql-credentials` is never in git, and it is an input: create it before the
first apply. The six required keys are `POSTGRESQL_USER`, `POSTGRESQL_PASSWORD`,
`POSTGRESQL_DATABASE`, `POSTGRESQL_ADMIN_PASSWORD`, `POSTGRESQL_MASTER_USER` and
`POSTGRESQL_MASTER_PASSWORD`.

```bash
oc -n plain-pg create secret generic postgresql-credentials \
  --from-literal=POSTGRESQL_USER=app \
  --from-literal=POSTGRESQL_PASSWORD='<app-pw>' \
  --from-literal=POSTGRESQL_DATABASE=appdb \
  --from-literal=POSTGRESQL_ADMIN_PASSWORD='<admin-pw>' \
  --from-literal=POSTGRESQL_MASTER_USER=replicator \
  --from-literal=POSTGRESQL_MASTER_PASSWORD='<repl-pw>'
```

To keep the values in a file instead, use a gitignored `envs` file with a
`secretGenerator` in your own kustomization:

```yaml
secretGenerator:
  - name: postgresql-credentials
    envs: [credentials.env]
    options: {disableNameSuffixHash: true}
```

Or an `ExternalSecret` from the External Secrets Operator, materializing
`postgresql-credentials` from Vault/AWS/GCP/Azure.

The test tooling generates a throwaway Secret in gitignored `secrets/`
(`scripts/generate-secret.sh`). That one is for the lab only.

## Scripts (test tooling)

`scripts/deploy.sh`, used by the test suite, re-applies the overlay while
preserving a live failover: it leaves the `postgresql-role` ConfigMap alone, and
applies the StatefulSet and the `-rw`/`-ro` Services with **merge patches** that
omit the operational fields (`spec.replicas` and `spec.selector`). So the role, the
routing and a replica count owned by the HPA survive, while everything else (for
example the Service `type` of `ha-external`) still applies. It generates a
throwaway Secret in gitignored `secrets/` and waits for the pods. It needs Python
with PyYAML when it reapplies over an existing deployment. The other scripts
(`verify-replication.sh`, `failover-manual.sh`, `backup-now.sh`,
`restore-backup.sh`, `reseed-replica.sh`, `read-load.sh`) are the day-2 helpers;
see `tests.md`.

## Metrics

`components/metrics` (overlay `ha-metrics`) adds a `postgres_exporter`, a
`Service` and a `ServiceMonitor`, so OpenShift's monitoring scrapes PostgreSQL:

```bash
oc apply -k manifests/overlays/ha-metrics
```

It needs the `monitoring.coreos.com` CRDs (the monitoring stack; MicroShift does
not ship them, and the component labels the namespace
`openshift.io/cluster-monitoring=true`). The exporter connects through
`postgresql-rw`, so it follows a failover, as the **application user**: the
entrypoint grants that user `pg_monitor` (a background task in the base
ConfigMap), so the exporter reads `pg_stat_*` without the superuser.

Its DSN uses `sslmode=disable` (the Go driver has no `prefer`). If you also use
`ha-tls`, patch it to `sslmode=require` (or `verify-ca` with the CA mounted):

```bash
oc -n plain-pg patch deploy postgresql-metrics --type merge -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"postgres-exporter","env":[{"name":"DATA_SOURCE_URI","value":"postgresql-rw:5432/postgres?sslmode=require"}]}]}}}}'
```

## TLS

`components/tls` mounts a certificate into the pods; the entrypoint turns TLS on
only when it is there (`ssl=on`, plus the CA for verification). Two components
provide the certificate:

- **`components/tls-service-ca`**: OpenShift's **service-ca** issues it for
  `postgresql-hl` into the Secret `postgresql-tls` and injects the CA into
  `postgresql-tls-ca`. Nothing is stored in git. Used by `ha-tls` (HA) and
  `single-tls` (one pod).
- **`overlays/ha-tls-byo`** (your own certificate): create the two objects, apply
  the overlay and recreate the pods:

```bash
oc -n plain-pg create secret tls postgresql-tls --cert=tls.crt --key=tls.key
oc -n plain-pg create configmap postgresql-tls-ca --from-file=ca.crt
oc apply -k manifests/overlays/ha-tls-byo
oc -n plain-pg delete pod postgresql-1 postgresql-0   # OnDelete: recreate to mount it
```

The certificate must be valid for the names clients use (the headless per-pod
DNS and the `-rw`/`-ro` Services). Clients verify with `sslmode=verify-ca`, or
`verify-full` with your own SANs, and `sslrootcert` pointing at the CA. The WAL
receiver, `psql` and `pg_dump` use TLS when the server offers it
(`PGSSLMODE=prefer`).

**TLS is required** for TCP connections: the component sets `PG_REQUIRE_TLS=true`
and the entrypoint turns the image's plaintext `host` rules in `pg_hba.conf` into
`hostssl`, so a client that does not use TLS is refused. Remove that env var (or
the component) to go back to offering TLS instead of requiring it. On a fresh
install the first `initdb` does not pick TLS up: restart the pods once.

## External access (NodePort)

`overlays/ha-external` publishes the primary through a **NodePort** on
`postgresql-rw` (port 30432), so a client outside the cluster reaches it at
`<node-ip>:30432`. A failover already repoints the selector, so external clients
follow the new primary.

```bash
./scripts/deploy.sh manifests/overlays/ha-external
oc get nodes -o wide                       # the node address
psql -h <node-ip> -p 30432 -U app -d appdb
```

**Security.** This publishes PostgreSQL on every node's address, and two things
must line up:

- **The NetworkPolicy still blocks external clients.** Add an `ipBlock` for the
  client network, as narrow as possible. The Service uses
  `externalTrafficPolicy: Local`, so the policy matches the client's real IP:

```bash
oc -n plain-pg patch networkpolicy postgresql-ingress --type merge -p \
  '{"spec":{"ingress":[{"from":[{"ipBlock":{"cidr":"203.0.113.0/24"}}],"ports":[{"protocol":"TCP","port":5432}]}]}}'
```

- **Use TLS.** Combine it with `ha-tls` or `ha-tls-byo`; otherwise the password
  and the data cross the network in clear text. Clients then use
  `sslmode=require` (or `verify-ca` with the CA).

Prefer a **private** node address, or a `LoadBalancer`/bastion with a firewall
allowlist, over a public one: a database on a public IP is scanned constantly.

## Verify and connect

```bash
./scripts/verify-replication.sh
oc -n plain-pg get pods,pvc,svc
oc -n plain-pg exec postgresql-0 -- psql -U postgres -c 'SELECT * FROM pg_stat_replication;'
```

Use the credentials you put in the Secret (see [Credentials](#credentials)).

```bash
NS=plain-pg
oc -n $NS exec -it postgresql-0 -- psql -h postgresql-rw -U app -d appdb   # writes
oc -n $NS exec -it postgresql-1 -- psql -h postgresql-ro -U app -d appdb   # reads
oc -n $NS exec -it postgresql-0 -- psql -h 127.0.0.1 -U postgres           # superuser
```

## Frequent tasks

```bash
oc -n plain-pg logs -f postgresql-0
oc -n plain-pg delete pod postgresql-1     # restart the replica (no impact)
oc -n plain-pg delete pod postgresql-0     # restart the primary (brief outage)
./scripts/backup-now.sh
./scripts/reseed-replica.sh postgresql-1         # re-seed a broken replica
```

Add a replica with `oc -n plain-pg scale sts postgresql --replicas=3`. Scaling back
leaves the removed pod's PVC orphaned
(`oc -n plain-pg delete pvc pgdata-postgresql-N`). Do not scale by hand while an
HPA owns `replicas` (see `scaling.md`).

## Recovery

- **Replica fell too far behind** (log: `requested WAL segment … has already been
  removed`): `./scripts/reseed-replica.sh postgresql-1`.
- **Failed promotion**: the declared state stays on the candidate and the
  ex-primary is isolated. Finish it by hand (`oc delete pod <candidate>`) or roll
  back explicitly. See `failover.md`.
- **The primary and replica PVCs are both lost**: the dumps on the
  `postgresql-backups` PVC are the only copy. Rebuild and load the last dump into
  the app database (`t30` runs exactly this):

```bash
oc -n plain-pg delete statefulset postgresql
oc -n plain-pg delete pvc pgdata-postgresql-0 pgdata-postgresql-1
./scripts/deploy.sh                                     # fresh, empty cluster
FORCE=1 ./scripts/restore-backup.sh /backups/<dump> appdb
```

  `FORCE=1` drops and recreates the app database and restores as the application
  user, so the restored objects belong to it. On a brand-new cluster, restore the
  roles from the `-globals.sql` file as well. Everything written after the last
  dump is lost.

## Sharp edges

- The real `PGDATA` is `/var/lib/pgsql/data/userdata`; the PVC mounts
  `/var/lib/pgsql/data`.
- Local connections (socket, `127.0.0.1`) are `trust`: from inside the pod no
  password is needed. Remote connections require the password.
- `oc apply` prints `configured` for the StatefulSet on every run even when
  nothing changed (the `volumeClaimTemplates` status); check real idempotency with
  `metadata.generation` (or the `resourceVersion` for objects without it), not
  with that word.
- `oc rollout status` does not work with `updateStrategy: OnDelete`; watch the
  pods instead.
