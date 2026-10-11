#!/usr/bin/env bash
#
# lib-test.sh -- mini-framework for the test suite.
# Sourced from each tests/tNN_*.sh.
#
# Usage:
#   check        "<desc>" <cmd...>
#   check_eq     "<desc>" <expected> <actual>
#   check_ne     "<desc>" <not-expected> <actual>
#   check_match  "<desc>" <regex> <text>
#   check_contains "<desc>" <substring> <text>
#   wait_for     <timeout_s> "<desc>" <cmd...>
#   c_skip       "<desc>"
#   t_summary    (at the end; sets the exit code)
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

PASS=0; FAIL=0; SKIP=0
FAILED_DESCS=()

c_ok()   { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
c_fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); FAILED_DESCS+=("$*"); }
c_skip() { echo "  [SKIP] $*"; SKIP=$((SKIP + 1)); }

check() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then c_ok "$d"; else c_fail "$d"; fi
}
check_eq() {
  local d="$1" e="$2" a="$3"
  if [ "$e" = "$a" ]; then c_ok "$d"; else c_fail "$d (expected='$e' got='$a')"; fi
}
check_ne() {
  local d="$1" e="$2" a="$3"
  if [ "$e" != "$a" ]; then c_ok "$d"; else c_fail "$d (should not be '$e')"; fi
}
check_match() {
  local d="$1" re="$2" s="$3"
  if printf '%s' "$s" | grep -Eq "$re"; then c_ok "$d"; else c_fail "$d (does not match /$re/: '$s')"; fi
}
check_contains() {
  local d="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then c_ok "$d"; else c_fail "$d (does not contain '$needle')"; fi
}

wait_for() {
  local t="$1" d="$2"; shift 2
  local i=0
  while [ "$i" -lt "$t" ]; do
    if "$@" >/dev/null 2>&1; then c_ok "$d"; return 0; fi
    sleep 3; i=$((i + 3))
  done
  c_fail "$d (timeout ${t}s)"
  return 1
}

pod_ready() {   # pod_ready <pod>
  [ "$(oc -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ]
}

t_summary() {
  echo
  echo "  ---- summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
  if [ "$FAIL" -gt 0 ]; then
    echo "  ---- failures:"
    for f in "${FAILED_DESCS[@]}"; do echo "        - $f"; done
    return 1
  fi
  return 0
}
