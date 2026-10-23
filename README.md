# plain-pg

Run PostgreSQL on OpenShift with plain Kubernetes manifests: one StatefulSet and a
ConfigMap that names the primary. No operator is required for the core install.

Start with one pod and daily `pg_dump` backups; choose the HA profile for a hot
standby and optional automatic failover. Every profile runs non-root under
PodSecurity `restricted`, with an ingress NetworkPolicy and the image pinned by
digest.

| | |
|---|---|
| Supported image | PostgreSQL 18 on a RHEL 10 container (`rhel10/postgresql-18`) |
| Objects | StatefulSet, Services, ConfigMaps, CronJobs, NetworkPolicy, PVCs. No CRDs |
| Verified by | 36 tests, 358 checks, against a real cluster ([evidence](docs/evidence/README.md)) |

## Requirements

- `oc` logged in, with permission to create the namespace and the objects in it.
- A default StorageClass: the StatefulSet creates its PVCs, and they are not
  deleted when it is.
- The credentials Secret, created by hand before the first apply; the exact
  command is in [Credentials](docs/operations.md#credentials).
- Pull access to `registry.redhat.io` from the nodes (a Red Hat pull secret).

## Try it

```bash
git clone https://github.com/rarguello/plain-pg.git && cd plain-pg

# 1. the namespace, with the PodSecurity labels the pods expect
oc apply -f manifests/base/namespace.yaml

# 2. the credentials, created by hand and never committed
oc -n plain-pg create secret generic postgresql-credentials \
  --from-literal=POSTGRESQL_USER=app \
  --from-literal=POSTGRESQL_PASSWORD='<app-pw>' \
  --from-literal=POSTGRESQL_DATABASE=appdb \
  --from-literal=POSTGRESQL_ADMIN_PASSWORD='<admin-pw>' \
  --from-literal=POSTGRESQL_MASTER_USER=replicator \
  --from-literal=POSTGRESQL_MASTER_PASSWORD='<repl-pw>'

# 3. one pod
oc apply -k manifests/overlays/single
oc -n plain-pg get pods                    # wait for 1/1 Ready
```

If you would rather keep the values in a file than on the command line, use an
`envs` file with a `secretGenerator`, or an `ExternalSecret`: see
[Credentials](docs/operations.md#credentials).

That is a working PostgreSQL behind `postgresql-rw`. To add a hot standby:

```bash
oc -n plain-pg scale sts postgresql --replicas=2
```

The new pod reads `PRIMARY_POD`, sees that it is not the primary, and runs
`pg_basebackup` on its own. Scaling adds the standby only: for the `postgresql-ro`
Service and automatic failover, apply `manifests/overlays/ha` instead (see
[Profiles](#profiles)).

Deploying this in your own repository, with your own namespace, StorageClass or
image, needs no editing: see
[Deploy with your own values](docs/operations.md#deploy-with-your-own-values).

## Compose what you need

The deployment is a kustomize base plus optional components, so your own setup is
one file. This one gives you a primary with a hot standby, 10Gi of data, a
NodePort for clients outside the cluster, automatic failover, and TLS that the
server requires (plaintext connections are refused), without editing anything
here:

```yaml
# my-postgres/kustomization.yaml, in your own repository
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: my-pg

# The HA profile: two pods, postgresql-ro, and the failover CronJob. Pin a tag
# or a commit instead of main when you want what you deploy to stop moving.
resources:
  - github.com/rarguello/plain-pg//manifests/overlays/ha?ref=main

components:
  - github.com/rarguello/plain-pg//manifests/components/tls?ref=main
  - github.com/rarguello/plain-pg//manifests/components/external-access?ref=main

patches:
  # 10Gi for the data and for the backups (the default is 2Gi).
  - target: {kind: StatefulSet, name: postgresql}
    patch: |-
      - op: replace
        path: /spec/volumeClaimTemplates/0/spec/resources/requests/storage
        value: 10Gi
  - target: {kind: PersistentVolumeClaim, name: postgresql-backups}
    patch: |-
      - op: replace
        path: /spec/resources/requests/storage
        value: 10Gi

  # Your clients' network. Add to the shipped rule: replacing it would also shut
  # out the pods in the namespace, and the failover CronJob reads that as a dead
  # primary.
  - target: {kind: NetworkPolicy, name: postgresql-ingress}
    patch: |-
      - op: add
        path: /spec/ingress/0/from/-
        value:
          ipBlock:
            cidr: 203.0.113.0/24
```

`components/tls` mounts a certificate and requires TLS, but it does not create it:
the certificate is yours, and the names in it decide what your clients can verify.
These commands use a self-signed one for the address clients connect to:

```bash
# 1. the objects; the pods wait for the credentials Secret
oc apply -k my-postgres

# 2. the certificate and the two objects it lives in. The SANs must cover the
#    address clients use: here the node, plus the Service name inside the cluster.
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout tls.key -out tls.crt -subj "/CN=<node-ip>" \
  -addext "subjectAltName=IP:<node-ip>,DNS:postgresql-rw.my-pg.svc"
oc -n my-pg create secret tls postgresql-tls --cert=tls.crt --key=tls.key
oc -n my-pg create configmap postgresql-tls-ca --from-file=ca.crt=tls.crt

# 3. the credentials last: they are what starts the pods, with TLS already mounted
oc -n my-pg create secret generic postgresql-credentials ...   # see Credentials

# 4. from your machine, verifying the certificate
psql "host=<node-ip> port=30432 dbname=appdb user=app \
      sslmode=verify-full sslrootcert=tls.crt"
```

Four things are worth knowing before you copy it:

- The Secret is an input: the pods wait for it, which is also why it is created
  last here.
- The certificate is an input too. While TLS is required, a pod that is not
  offering it is not Ready, so the database never takes clients in plaintext. A
  self-signed certificate is enough to start; a real deployment uses one from your
  PKI, and `overlays/ha-tls-byo` is the same shape inside this repository. If you
  would rather let the cluster issue it, add `components/tls-service-ca` and drop
  the two objects above: its certificate covers the in-cluster names only, so
  clients use `sslmode=require`, or `verify-ca` with the CA from the
  `postgresql-tls-ca` ConfigMap.
- The NodePort is published on every node's address: keep it on a private
  interface or behind a firewall, and narrow the `ipBlock` to your clients.
- A failover repoints `postgresql-rw`, so external clients follow the new primary
  without changing anything on their side.

## Profiles

An **overlay** is a kustomize directory that selects which objects are deployed; a
**profile** is the choice of overlay. Every profile shares the same base and the
same hardening.

| Overlay | Pods | What you get |
|---|---:|---|
| `single` | 1 | one pod, the same hardening and backups |
| `single-tls` | 1 | the same, serving TLS |
| `ha` | 2 | a hot standby, `postgresql-ro`, automatic failover |
| `ha-manual` | 2 | a hot standby, manual failover only |
| `ha-metrics` | 2 | `ha` plus the Prometheus exporter |
| `ha-tls` | 2 | `ha` plus TLS, certificate from service-ca |
| `ha-tls-byo` | 2 | `ha` plus TLS, your own certificate |
| `ha-external` | 2 | `ha` plus a NodePort on `postgresql-rw` |
| `ha-autoscale` | 2 | `ha` plus the read HPA |

The components under `manifests/components/` combine, so your own mix needs no new
overlay: a six-line kustomization is enough (see
[operations.md](docs/operations.md#overlays)).

## How it works

![The HA profile: clients write through postgresql-rw to the primary and read
through postgresql-r or postgresql-ro; the primary streams WAL to the hot standby;
a headless Service gives each pod a DNS name; a CronJob writes pg_dump backups to
a PVC, and an optional CronJob promotes a standby](docs/architecture.svg)

`postgresql-rw` carries writes to the primary. `postgresql-r` spreads reads over
every Ready pod. `postgresql-ro` pins one standby. The primary streams its WAL to
the standby, `postgresql-hl` gives each pod a DNS name so a standby can find the
primary, and each pod keeps its data on its own `pgdata-postgresql-N` PVC.

### How the primary is chosen

`postgresql-0` is primary by convention, not by code. On startup each pod reads
`PRIMARY_POD` from the `postgresql-role` ConfigMap and, if it matches its own name,
starts as primary; otherwise it starts as a standby of the named pod. There is no
leader election: the role is an explicit value, changed on purpose.

The entrypoint brings `PGDATA` to the assigned role:

| Desired | `PGDATA` holds | Action |
|---|---|---|
| primary | empty | `initdb` and user creation (the image does both) |
| primary | standby data | delete `standby.signal` → promote |
| standby | empty | `pg_basebackup` from the primary |
| standby | primary data | wipe and re-seed |
| standby | standby data | start and refresh `primary_conninfo` |

A failover is changing that value and recreating the pods; a pod that comes back
with the wrong role re-seeds or promotes itself on startup.

## Why this exists

One PostgreSQL server is a single point of failure and one server's worth of
reads. PostgreSQL ships the fix: **streaming replication**, where the primary
streams its WAL (write-ahead log) to a hot standby that answers read-only
queries. What it does not ship are the parts around it: deciding when to promote,
keeping `primary_conninfo` current, and repointing clients.

| Approach | Remaining work |
|---|---|
| PostgreSQL on two hosts | build the standby, promote on failure, re-seed the old primary, repoint clients |
| The image in a plain StatefulSet | pods restart and reschedule, but nothing configures replication, picks the primary or repoints the Services |
| An HA stack (CloudNativePG, Patroni, …) | more automation, and another system to run |

This repository does that work with PostgreSQL's own replication and plain
objects: a ConfigMap holds the role, the entrypoint configures each pod for it,
reads scale through `postgresql-r`, and failover is a script or a CronJob.

## Security

Included in every profile:

- **Non-root and `restricted`**: `runAsNonRoot`, `allowPrivilegeEscalation:
  false`, all capabilities dropped, `seccompProfile: RuntimeDefault`; the pods run
  under the `restricted` PodSecurity profile.
- **A pinned image**: a Red Hat PostgreSQL image referenced by digest, from
  `registry.redhat.io`.
- **An ingress NetworkPolicy**: PostgreSQL on 5432 is reachable from pods in the
  namespace only. It does not isolate the database pods from each other, and
  egress is not restricted.
- **Credentials outside git**: the Secret is created by hand (or materialized by
  an ExternalSecret); the test tooling generates a throwaway one.

Not enabled by default:

- **TLS**: `ha-tls` (certificate issued by OpenShift's service-ca) or `ha-tls-byo`
  (your own). The component also sets `PG_REQUIRE_TLS`, which turns the plaintext
  rules in `pg_hba.conf` into `hostssl`, so a client that does not use TLS is
  refused. See [TLS](docs/operations.md#tls).
- **External access**: `ha-external` publishes the primary on a NodePort. Read
  [External access](docs/operations.md#external-access-nodeport) first.
- **RBAC for the failover CronJob**: the `automatic-failover` component adds a
  ServiceAccount, Role and RoleBinding limited to pods and the role ConfigMap.

## Limits

| Limit | Consequence |
|---|---|
| Fencing is pod-level, not STONITH | a node partitioned from the API server can leave two primary processes |
| Replication is asynchronous | a failover can lose the last unreplicated transactions |
| Backups are logical (`pg_dump`), no WAL archiving | no point-in-time recovery; the copies live in the cluster |
| No connection pooler | every client connection is a PostgreSQL process (100 per pod), and a failover drops them all: the clients must reconnect |
| The image writes `md5` in `pg_hba.conf` | PostgreSQL 18 deprecates it and logs warnings; `ha-settings` replaces it with `scram-sha-256` in two lines (`md5` rules still use SCRAM when the stored password is a SCRAM hash) |
| No operator, no consensus | failover is manual or an optional best-effort CronJob, not turnkey HA |
| The single profile | a restart, an upgrade or a node failure is downtime |

## Tests and evidence

The suite runs against a real cluster: **36 tests, 358 checks**, covering deploy,
the single-instance profile and the step to HA, replication, manual and automatic
failover, persistence, backups, disaster recovery, scaling, the HPA, metrics, TLS
and external access. The last full run: 36/36, 0 failures
([transcript](docs/evidence/2026-10-23-tls-first-start-full-suite.txt)).

CI lints and validates the manifests on every push. A nightly job creates a
throwaway MicroShift cluster inside the runner and runs the non-destructive
`quick` subset (14 tests) against it. See [docs/tests.md](docs/tests.md).

The bundled configuration uses PostgreSQL 18 on RHEL 10. Four other images passed
the same suite but are not supported; results, transcripts and the procedure to
switch are in [Supported images](docs/supported-images.md).

## Documentation

- [operations.md](docs/operations.md): deploy, profiles, changing the image, credentials, metrics, TLS, external access, recovery
- [failover.md](docs/failover.md): how the role moves, manual and automatic, and the guarantees it does not give
- [backups.md](docs/backups.md): `pg_dump`, restore, disaster recovery, and what they do not cover
- [scaling.md](docs/scaling.md): the Services and the read HPA
- [supported-images.md](docs/supported-images.md): what has been tested, what is supported, how to switch
- [tests.md](docs/tests.md): the suite, its requirements, MicroShift
- [evidence/](docs/evidence/README.md): raw transcripts of full runs
- [AGENTS.md](AGENTS.md): the rules this repository follows

MIT. See [LICENSE](LICENSE).
