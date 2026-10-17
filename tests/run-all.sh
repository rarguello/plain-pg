#!/usr/bin/env bash
#
# run-all.sh -- runs the test suite.
#
# Usage:
#   ./tests/run-all.sh              # all (includes destructive: failover, teardown)
#   ./tests/run-all.sh quick       # only the non-destructive ones
#   ./tests/run-all.sh t03 t04      # specific tests
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

# Every test starts from a deployed lab. deploy.sh is idempotent and does not
# revert a failover, so ensuring it here is safe on an existing lab and makes the
# suite work from scratch.
DEPLOY_LOG="$(mktemp)"
trap 'rm -f "$DEPLOY_LOG"' EXIT
echo "== ensuring the lab is deployed (scripts/deploy.sh)"
if ! "$ROOT_DIR/scripts/deploy.sh" >"$DEPLOY_LOG" 2>&1; then
  echo "== FATAL: scripts/deploy.sh could not deploy the lab:"
  sed 's/^/   /' "$DEPLOY_LOG"
  exit 1
fi

# deploy.sh does not recreate pods (updateStrategy is OnDelete), so a lab left in
# another shape by an interrupted run would still be running the old pods. Start
# from pods that match the manifests.
echo "== restarting the pods so they match the manifests"
oc -n "${NAMESPACE:-plain-pg}" delete pod -l app.kubernetes.io/component=database \
  --ignore-not-found >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  ready="$(oc -n "${NAMESPACE:-plain-pg}" get pods -l app.kubernetes.io/component=database \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
    | grep -c true || true)"
  [ "${ready:-0}" -ge 2 ] && break
  sleep 5
done

ALL=(t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12 t13 t14 t15 t16 t17 t18 t19 t20 t21 t22 t23 t24 t25 t26 t27 t28 t29 t30 t31 t32 t33 t34 t35 t36 t37)
QUICK=(t01 t02 t03 t04 t05 t06 t09 t10 t12 t14 t18 t19 t21 t22)

if [ "$#" -eq 0 ]; then
  SEL=("${ALL[@]}")
elif [ "$1" = "quick" ]; then
  SEL=("${QUICK[@]}")
else
  SEL=("$@")
fi

RESULT=()
START="$(date +%s)"

for t in "${SEL[@]}"; do
  f="$(ls "$ROOT_DIR"/tests/"$t"_*.sh 2>/dev/null | head -1)"
  if [ -z "$f" ]; then
    echo "== $t: not found"
    RESULT+=("FAIL $t (no such test)")
    continue
  fi
  echo
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo "== $(basename "$f")"
  echo "═══════════════════════════════════════════════════════════════════════════"
  if bash "$f"; then
    RESULT+=("PASS $t")
  else
    RESULT+=("FAIL $t")
  fi
done

END="$(date +%s)"
echo
echo "═══════════════════════════════════════════════════════════════════════════"
echo "== SUMMARY  ($((END - START))s)"
echo "═══════════════════════════════════════════════════════════════════════════"
for r in "${RESULT[@]}"; do printf '  %s\n' "$r"; done

if grep -q '^FAIL' <<< "$(printf '%s\n' "${RESULT[@]}")"; then
  echo
  echo "  RESULT: THERE ARE FAILURES"
  exit 1
fi
echo
echo "  RESULT: ALL OK"
