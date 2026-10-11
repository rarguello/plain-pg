# Use cases

Concrete situations where `plain-pg` fits, and where it does not.

## Fits

**Internal application, one hot replica, nightly dumps.**
An internal tool (wiki, CI, dashboard, small SaaS) needs its database to survive
a pod failure and to have a real backup. Reads go to `postgresql-r`, writes to
`postgresql-rw`, backups run from the CronJob. A failover is a script you run and
understand.

**Read-heavy reporting on top of a small write load.**
Reports connect to `postgresql-r` and get spread over the replicas. If report
traffic spikes, the HPA adds replicas. Writes keep going to the primary.

**Learning / teaching / reference.**
There is no operator magic: the whole thing is a StatefulSet, four Services, two
ConfigMaps and two CronJobs. It is meant to be read in one sitting. It is also a
good base for explaining streaming replication, WAL, hot standby, and why real
HA needs consensus and fencing.

**Air-gapped or permission-constrained clusters.**
If you cannot install an operator (no CRD/OLM permissions) but still need a
replica and backups, this runs with what the cluster already has.

**Lab / demo on a single node (SNO).**
The default overlay is designed to work on a one-node OpenShift cluster.

## Does not fit

**Anything where a silent split-brain is unacceptable.**
The failover is verified at the pod level, not with real fencing (STONITH). A
node partition can produce two primaries. Use an operator with consensus
(CloudNativePG, Zalando, Crunchy) or plain Patroni.

**Zero data loss on failover.**
Replication is asynchronous by default: a failover can lose the last
transactions. You can enable synchronous replication, but then a replica outage
blocks writes.

**Point-in-time recovery / restore to a timestamp.**
Backups are logical (`pg_dump`); there is no WAL archiving. If you need "restore
to 14:32 yesterday", you need WAL archiving and a tool like Barman, pgBackRest
or WAL-G (or an operator that bundles them).

**Many clusters, full lifecycle in Git.**
If you run dozens of databases and want upgrades, pooling, metrics and failover
declared and reconciled, the operator is worth its complexity.

**Regulated workloads with strict RPO/RTO.**
A manual failover plus async replication is not an RPO/RTO story you can put in
front of an auditor.

## A decision shortcut

Ask three questions:

1. **Can a human run the failover, and is a few minutes of downtime fine?**
   No → use an operator.
2. **Can you afford to lose the last unreplicated transaction?**
   No → use synchronous replication (here or elsewhere), or an operator with it
   on by default.
3. **Do you need restore-to-a-point-in-time?**
   Yes → you need WAL archiving; this repo does not do it.

If all three answers point to "it's fine", `plain-pg` is enough and you will
understand every part of it.
