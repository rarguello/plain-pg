# Operations

## Deploy

A real install is just manifests: create the namespace and the credentials Secret
by hand, then apply. The primary runs `initdb` and the replica `pg_basebackup` on
startup, so there is nothing else to run.

```bash
oc apply -f manifests/base/namespace.yaml
# create the Secret first: the full command is under Credentials, below
oc apply -k manifests/overlays/lab
oc -n plain-pg get pods      # wait for 2/2 Ready
```

Re-applying the overlay on a live cluster **resets** `PRIMARY_POD`, the
`-rw`/`-ro` selectors and `spec.replicas` — it would revert a failover and fight an
HPA. To change something live, patch that object; to return to the initial primary,
`./scripts/failover-manual.sh postgresql-0`.

For manual failover only (no failover CronJob), apply
`manifests/overlays/lab-manual` instead.

`plain-pg` is only the example namespace. To deploy elsewhere, change
`metadata.name` in `manifests/base/namespace.yaml`, the `namespace:` field in each
overlay (`lab`, `lab-manual`, `lab-autoscale`), and `NS` in `scripts/lib.sh`; the
commands in this document then need the same namespace.

## Credentials

`postgresql-credentials` is never in git. Create it by hand before the apply; the
test tooling generates a throwaway one. The command:

```bash
oc -n plain-pg create secret generic postgresql-credentials \
  --from-literal=POSTGRESQL_USER=app                --from-literal=POSTGRESQL_PASSWORD='<app-pw>' \
  --from-literal=POSTGRESQL_DATABASE=appdb           --from-literal=POSTGRESQL_ADMIN_PASSWORD='<admin-pw>' \
  --from-literal=POSTGRESQL_MASTER_USER=replicator   --from-literal=POSTGRESQL_MASTER_PASSWORD='<repl-pw>'
```

Required keys: `POSTGRESQL_USER`, `POSTGRESQL_PASSWORD`, `POSTGRESQL_DATABASE`,
`POSTGRESQL_ADMIN_PASSWORD`, `POSTGRESQL_MASTER_USER`, `POSTGRESQL_MASTER_PASSWORD`.

Neither of these is shipped or tested here; they are integration options if you
prefer not to create the Secret by hand:

- a `secretGenerator` in your own kustomization (with
  `options.disableNameSuffixHash: true`), reading a gitignored `envs` file; or
- an `ExternalSecret` from the External Secrets Operator that materializes
  `postgresql-credentials` from Vault/AWS/GCP/Azure.

## Scripts (test tooling)

`scripts/deploy.sh`, used by the test suite, is a wrapper that re-applies the
overlay while preserving a failover: it skips the `postgresql-role` ConfigMap and
the `-rw`/`-ro` Services, applies the StatefulSet server-side without
`spec.replicas`, generates a throwaway Secret in gitignored `secrets/`, and waits
for the pods. It needs Python with PyYAML when it reapplies over an existing
deployment. The other scripts (`verify-replication.sh`, `failover-manual.sh`,
`backup-now.sh`, `restore-backup.sh`, `reseed-replica.sh`, `read-load.sh`) are the
day-2 helpers; see `tests.md`.

## Metrics

`components/metrics` (overlay `lab-metrics`) adds a `postgres_exporter`, a
`Service` and a `ServiceMonitor`, so OpenShift's monitoring scrapes PostgreSQL:

```bash
oc apply -k manifests/overlays/lab-metrics
```

It needs the `monitoring.coreos.com` CRDs (the monitoring stack; MicroShift does
not ship them, and the component labels the namespace
`openshift.io/cluster-monitoring=true`). The exporter connects through
`postgresql-rw`, so it follows a failover, as the superuser because the default
queries read `pg_stat_*`; for production create a role with `pg_monitor` and
point `DATA_SOURCE_USER` at it.

## TLS

`components/tls` mounts a certificate into the pods; the entrypoint turns TLS on
only when it is there (`ssl=on`, plus the CA for verification). Two overlays
provide the certificate:

- **`lab-tls`** — OpenShift's **service-ca** issues it for `postgresql-hl` into
  the Secret `postgresql-tls` and injects the CA into `postgresql-tls-ca`.
  Nothing is stored in git.
- **`lab-tls-byo`** — **your own certificate**: create the two objects, apply the
  overlay and recreate the pods:

```bash
oc -n plain-pg create secret tls postgresql-tls --cert=tls.crt --key=tls.key
oc -n plain-pg create configmap postgresql-tls-ca --from-file=ca.crt
oc apply -k manifests/overlays/lab-tls-byo
oc -n plain-pg delete pod postgresql-1 postgresql-0   # OnDelete: recreate to mount it
```

The certificate must be valid for the names clients use (the headless per-pod
DNS and the `-rw`/`-ro` Services). Clients verify with `sslmode=verify-ca`, or
`verify-full` with your own SANs, and `sslrootcert` pointing at the CA. The WAL
receiver, `psql` and `pg_dump` use TLS when the server offers it
(`PGSSLMODE=prefer`). TLS is offered, not required; to require it, add a
`hostssl` line to `pg_hba.conf` and drop the plaintext `host` lines. On a fresh
install the first `initdb` does not pick TLS up: restart the pods once.

## External access (NodePort)

`overlays/lab-external` publishes the primary through a **NodePort** on
`postgresql-rw` (port 30432), so a client outside the cluster reaches it at
`<node-ip>:30432`. A failover already repoints the selector, so external clients
follow the new primary.

```bash
./scripts/deploy.sh manifests/overlays/lab-external
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

- **Use TLS.** Combine it with `lab-tls` or `lab-tls-byo`; otherwise the password
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
  `postgresql-backups` PVC are the only copy. Rebuild the cluster, recreate the app
  database and roles, then load a dump into it. `restore-backup.sh` only restores
  into a *new* database on a healthy cluster; it is not a disaster-recovery
  procedure by itself.

## Sharp edges

- The real `PGDATA` is `/var/lib/pgsql/data/userdata`; the PVC mounts
  `/var/lib/pgsql/data`.
- Local connections (socket, `127.0.0.1`) are `trust`: from inside the pod no
  password is needed. Remote connections require the password.
- `oc apply` prints `configured` for the StatefulSet on every run even when
  nothing changed (the `volumeClaimTemplates` status); check real idempotency with
  the `resourceVersion`, not with that word.
- `oc rollout status` does not work with `updateStrategy: OnDelete`; watch the
  pods instead.
