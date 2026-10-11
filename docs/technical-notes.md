# Technical notes

Details that cost time if you do not know them.

## Image

- The **real PGDATA** is `/var/lib/pgsql/data/userdata`, not `/var/lib/pgsql/data`.
  It is set by `set_pgdata()` from `common.sh`; the PVC is mounted at `/var/lib/pgsql/data`.
- The UBI10 image **does not include `hostname`**. It uses `${HOSTNAME:-$(uname -n)}`.
- `start/set_passwords.sh` (image hook) already runs
  `ALTER USER <replicator> WITH REPLICATION`, so it does not need to be granted.
- **The replica cannot use `run-postgresql`**: that path sources hooks that run
  `ALTER USER`, and on a standby (read-only) they fail and abort startup. The
  replica does `exec postgres` directly, like `run-postgresql-slave`.
- `initdb` leaves local authentication at `trust`, so `psql` over the socket
  inside the pod works without a password.

## Image digest

`registry.redhat.io/rhel10/postgresql-18:latest` is multi-architecture. The
digest pinned in the overlay is that of the **manifest list**, which is
independent of the architecture. In the pod:

- `.status.containerStatuses[].image` → the pinned reference (manifest list);
- `.status.containerStatuses[].imageID` → the digest of the **amd64** image,
  which is different.

That is why they cannot be compared with each other. To update the pin:
`./scripts/update-digest.sh --apply`.

## `oc apply` and idempotency

On a StatefulSet with `volumeClaimTemplates`, `kubectl`/`oc apply` (client-side)
prints `configured` on **every** run even if nothing changes: the three-way merge
always builds a patch for the `status` of the PVC template. **It does not mean
there are changes.** Real idempotency is checked with the `resourceVersion` of
the objects (that is what `tests/t09_idempotency.sh` does).

## `oc rollout status` does not work with `OnDelete`

```
error: rollout status is only available for RollingUpdate strategy type
```

The StatefulSet uses `OnDelete` on purpose (a database should not be restarted by
an `oc apply`). To wait for the deployment you have to watch the pods: see
`wait_db_ready()` in `scripts/lib.sh`.

## Labels of auxiliary pods

The Services select pods by label. A pod of a CronJob that carries
`app.kubernetes.io/name: postgresql` **enters as an endpoint** of `postgresql-hl`
(with `publishNotReadyAddresses: true` it enters even before being ready) and
breaks connections. That is why the backup and failover pods use
`app.kubernetes.io/name: pg-backup` / `pg-failover`. There is a regression test
(`tests/t19_selectors.sh`).

## NetworkPolicy is additive

NetworkPolicies **only add** permissions: traffic is allowed if *some* policy
that selects the pod allows it. You cannot "deny" by adding another policy; you
have to remove or adjust the one that allows. (Relevant if you want to isolate a
pod: creating an empty policy is not enough.)

## Replica session and `primary_conninfo`

`postgresql.auto.conf` (in the PVC) includes a recovery file that lives in
`$HOME` (outside the PVC, lost when the container is recreated). The entrypoint
does `touch` on that file on every startup so the `include` does not fail; if
not, PostgreSQL does not start due to "could not open configuration file".

## The Kubernetes API returns indented JSON

A "bare" `curl` against the API returns the JSON **multiline**
(`{\n  "kind": …`), unlike `oc get --raw`. If it is parsed with
`grep -o '"key":"value"'` it never matches. The failover controller compacts
the response before parsing (`tr -d ' \n\r\t'`) and sends its logs to **stderr**
so as not to contaminate the body captured in a command substitution.

## Local vs remote authentication

`initdb` leaves **local** connections (unix socket, 127.0.0.1, ::1) at `trust`,
and the image appends `host all all all md5` and `host replication all all md5`.
Since pg_hba is evaluated top to bottom:

- from **inside the pod** (127.0.0.1) no password is needed: it is equivalent to
  having a shell in the container;
- from **another pod** (pod IP) the first matching line is
  `host all all all md5`, so the password is required.

If you also want to close local access, change those lines to `scram-sha-256` in
`pg_hba.conf` (it can be done with a `postgresql-start` hook).

## Connection timeouts

Against a primary isolated by network, a TCP connection without a timeout can
take ~2 minutes (kernel SYN retries). That is why the failover controller uses
`PGCONNECT_TIMEOUT=5` and `curl --connect-timeout 5 --max-time 30`. Without
that, the health check "hangs" instead of failing fast.

## `podManagementPolicy: Parallel`

With `OrderedReady`, if the primary is `postgresql-1` (after a failover) and both
pods are recreated at once, the StatefulSet waits for `postgresql-0` (replica) to
create `postgresql-1`, and `postgresql-0` waits for its primary → deadlock. That is
why it is `Parallel` and the wait for the primary is explicit in the entrypoint.

## Reapplying manifests after a failover

The overlay declares `PRIMARY_POD=postgresql-0` and the original selectors, because
that is the *initial* state. `deploy.sh` saves the current operating state
(ConfigMap + selectors) and restores it after applying, so as not to revert a
failover. To go back to the initial state on purpose: `deploy.sh --reset-role`.
