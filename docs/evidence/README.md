# Test evidence

Raw output of `tests/run-all.sh` runs against the lab (OpenShift 4.21, single
node). Each file is one full run; the summary at the end is authoritative. A
`SKIP` is not a pass.

| File | Date | Result |
|---|---|---|
| [`2026-10-11-full-suite.txt`](2026-10-11-full-suite.txt) | 2026-10-11 | 23/23 tests, 233 checks, 0 failures |

Reproduce with `./tests/run-all.sh` (destructive) or `./tests/run-all.sh quick`.
