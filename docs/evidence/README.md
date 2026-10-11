# Test evidence

Runs of the suite (`tests/run-all.sh`) against the lab cluster
(OpenShift 4.21, SNO `sno.virt.daytwo.dev`).

Each file is the full output of one run. At the end is the per-test summary and
the overall result.

| File | Date | Result |
|---|---|---|
| [`2026-10-11-suite-completa.txt`](2026-10-11-suite-completa.txt) | 2026-10-11 | 23/23 tests, 232 checks, 0 failures |

How to reproduce:

```bash
./tests/run-all.sh            # all (includes destructive)
./tests/run-all.sh quick     # only the non-destructive
```
