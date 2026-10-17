# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:
<https://github.com/rarguello/plain-pg/security/advisories/new> (the **Security**
tab of this repository, then **Report a vulnerability**). Please do not open a
public issue for a security problem.

Expect an answer within a week. This is a personal project: there is no support
contract and no service level.

## What is in scope

The manifests, scripts and test tooling in this repository: the deployment, the
role handling, the failover scripts, the backups and the TLS wiring.

Out of scope: the PostgreSQL image and the metrics exporter image (report those to
Red Hat and to the exporter's maintainers), and anything about the cluster you run
this on.

## What this repository assumes

- The credentials Secret is created by hand and is never in git.
- The image is pinned by digest; a scheduled job reports when the pin drifts.
- Every profile runs non-root under the PodSecurity `restricted` profile, with an
  ingress NetworkPolicy.

The limits that matter are in the README and in [docs/failover.md](docs/failover.md):
fencing is pod-level (not STONITH), replication is asynchronous, backups are
logical (no point-in-time recovery), and there is no connection pooler.

## Scorecard findings that are deliberate

The OSSF Scorecard reports a few things this repository does not do. The reasons
are here so nobody has to guess.

Code review: this is a solo project. Pull requests are validated by CI (lint, the
manifests, the secret scan, and the nightly suite), not by a second reviewer, and
branch protection does not require an approval.

Maintained: Scorecard scores a project created in the last 90 days as zero on that
check. There is nothing to do about it; it clears itself with time.

CII Best Practices badge and fuzzing: there is nothing to fuzz here, since the
repository is YAML with a small amount of shell and Python, and the badge has not
been applied for.

Pinned dependencies and token permissions are addressed: every action is pinned by
commit SHA, and each workflow declares read-only permissions unless a job needs
more.
