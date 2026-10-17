# Test evidence

Raw output of `tests/run-all.sh` runs against a real cluster (OpenShift 4.21,
single node). One file per full run; the summary at the end of each is
authoritative. A `SKIP` is not a pass.

| File | Date | Image | Result |
|---|---|---|---|
| [`2026-10-17-full-suite.txt`](2026-10-17-full-suite.txt) | 2026-10-17 | `rhel10/postgresql-18` (supported) | 33/33 tests, 333 checks, 0 failures |
| [`2026-10-17-rhel9-postgresql-18-full-suite.txt`](2026-10-17-rhel9-postgresql-18-full-suite.txt) | 2026-10-17 | `rhel9/postgresql-18` | 32/32 tests, 317 checks, 0 failures |
| [`2026-10-17-rhel9-postgresql-16-full-suite.txt`](2026-10-17-rhel9-postgresql-16-full-suite.txt) | 2026-10-17 | `rhel9/postgresql-16` | 32/32 tests, 317 checks, 0 failures |
| [`2026-10-17-rhel10-postgresql-16-full-suite.txt`](2026-10-17-rhel10-postgresql-16-full-suite.txt) | 2026-10-17 | `rhel10/postgresql-16` | 32/32 tests, 317 checks, 0 failures |
| [`2026-10-17-rhel9-postgresql-15-full-suite.txt`](2026-10-17-rhel9-postgresql-15-full-suite.txt) | 2026-10-17 | `rhel9/postgresql-15` | 32/32 tests, 317 checks, 0 failures |

Which image is supported, and how to test another one, is in
[supported-images.md](../supported-images.md). Reproduce a run with
`./tests/run-all.sh` (destructive), `./tests/run-all.sh quick`, or
`./scripts/test-image.sh <repo>` for another image.
