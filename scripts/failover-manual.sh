#!/usr/bin/env bash
#
# failover-manual.sh -- promotes a replica to primary.
#
# Usage:
#   ./scripts/failover-manual.sh              # picks the first replica
#   ./scripts/failover-manual.sh postgresql-1   # explicit candidate
#   FORCE=1 ./scripts/failover-manual.sh      # no confirmation
#
# Order (declare, repoint the Services, fence, then promote):
#   0. Disables automatic failover while the operation lasts (if it was active)
#      so that the CronJob does not interfere.
#   1. ConfigMap PRIMARY_POD=<candidate>, with resourceVersion control.
#   2. Services: -rw -> candidate, -ro -> ex-primary.
#   3. Verifiable FENCING of the ex-primary: it is deleted and it waits to
#      confirm that the pod disappeared or changed UID. An API error (other than
#      "does not exist") aborts and reverts.
#   4. Recreates the candidate pod -> it is promoted.
#   5. Waits to confirm. If it does not promote, it is NOT reverted (the
#      ex-primary is already isolated): it warns loudly and is left for manual
#      intervention.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_credentials

FENCE_TIMEOUT="${FENCE_TIMEOUT:-120}"

OLD="$(primary_pod)"
CANDIDATE="${1:-}"
if [ -z "$CANDIDATE" ]; then
  CANDIDATE="$(replica_pods | head -1)"
fi

if [ -z "$CANDIDATE" ]; then
  echo "ERROR: there is no candidate replica." >&2
  exit 1
fi
if [ "$CANDIDATE" = "$OLD" ]; then
  echo "ERROR: the candidate ($CANDIDATE) is already the declared primary." >&2
  exit 1
fi
case "$CANDIDATE" in
  postgresql-0|postgresql-1) ;;
  *) echo "ERROR: only postgresql-0 or postgresql-1 can be primary; the HPA may remove higher ordinals." >&2
     exit 1 ;;
esac
if [ "$(pod_in_recovery "$CANDIDATE")" != "t" ]; then
  echo "ERROR: $CANDIDATE is not a reachable standby." >&2
  exit 1
fi

echo "Failover: $OLD (primary) -> $CANDIDATE (replica)"
if [ "${FORCE:-0}" != "1" ]; then
  read -r -p "Continue? [y/N] " answer
  [ "$answer" = "y" ] || { echo "Canceled."; exit 1; }
fi

# --- helpers ---------------------------------------------------------------
set_cm_primary() {   # $1 = pod, $2 = resourceVersion (optional)
  local body
  if [ -n "${2:-}" ]; then
    body="{\"metadata\":{\"resourceVersion\":\"$2\"},\"data\":{\"PRIMARY_POD\":\"$1\"}}"
  else
    body="{\"data\":{\"PRIMARY_POD\":\"$1\"}}"
  fi
  oc -n "$NS" patch configmap postgresql-role --type merge -p "$body" >/dev/null
}
set_services() {   # $1 = primary, $2 = replica; tries both
  local ok=0
  oc -n "$NS" patch svc postgresql-rw \
    -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$1\"}}}" >/dev/null || ok=1
  oc -n "$NS" patch svc postgresql-ro \
    -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$2\"}}}" >/dev/null || ok=1
  return "$ok"
}
svc_pod() { oc -n "$NS" get svc "$1" -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null || true; }
restore_state() {   # $1 = primary, $2 = replica
  set_cm_primary "$1" || true
  set_services "$1" "$2" || true
  local cm rw ro
  cm="$(cm_value PRIMARY_POD || true)"
  rw="$(svc_pod postgresql-rw)"
  ro="$(svc_pod postgresql-ro)"
  if [ "$cm" != "$1" ] || [ "$rw" != "$1" ] || [ "$ro" != "$2" ]; then
    echo "CRITICAL: inconsistent state after reverting (CM=$cm rw=$rw ro=$ro)" >&2
    return 1
  fi
  # The real PostgreSQL role must also be correct.
  if [ "$(pod_in_recovery "$1")" != "f" ]; then
    echo "CRITICAL: after reverting, $1 does NOT respond as primary. Intervention required." >&2
    return 1
  fi
  return 0
}
pod_state() {   # "gone" | "uid:<uid>" | "error:<msg>"
  local out rc
  out="$(oc -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}' 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then printf 'uid:%s' "$out"; return 0; fi
  case "$out" in
    *NotFound*|*"not found"*) printf 'gone' ;;
    *) printf 'error:%s' "$out" ;;
  esac
}
# 0 if the pod exists with that uid and without deletionTimestamp (intact).
pod_intact() {   # $1 = pod, $2 = uid
  local out rc
  out="$(oc -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}:{.metadata.deletionTimestamp}' 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ "$out" = "$2:" ]
}
fence_pod() {   # 0 = isolated; 1 = no changes (safe to revert); 2 = delete accepted, unconfirmed
  local pod="$1" state uid t=0
  state="$(pod_state "$pod")"
  case "$state" in
    gone)    echo "      $pod no longer exists"; return 0 ;;
    error:*) echo "ERROR: could not query $pod ($state)" >&2; return 1 ;;
    uid:*)   uid="${state#uid:}" ;;
  esac
  echo "      deleting $pod (uid ${uid:0:8}) and waiting for its termination"
  if ! oc -n "$NS" delete pod "$pod" --wait=false >/dev/null; then
    # The DELETE failed: it is only reverted if the pod is still intact.
    if pod_intact "$pod" "$uid"; then
      echo "ERROR: could not delete $pod (still intact; no changes)" >&2; return 1
    fi
    echo "ERROR: the DELETE of $pod failed and the pod is not intact" >&2; return 2
  fi
  while [ "$t" -lt "$FENCE_TIMEOUT" ]; do
    sleep 3; t=$((t + 3))
    state="$(pod_state "$pod")"
    case "$state" in
      gone)    echo "      $pod disappeared"; return 0 ;;
      error:*) echo "ERROR: could not confirm the termination of $pod ($state)" >&2; return 2 ;;
      uid:*)   if [ "${state#uid:}" != "$uid" ]; then
                 echo "      $pod recreated (new uid)"; return 0
               fi ;;
    esac
  done
  echo "ERROR: $pod did not terminate in ${FENCE_TIMEOUT}s (delete already accepted)" >&2
  return 2
}

# --- 1) Prevent automatic failover from interfering ------------------------
AUTO_BEFORE="$(cm_value AUTO_FAILOVER || true)"
if [ "$AUTO_BEFORE" = "true" ]; then
  echo "[0/5] Disabling AUTO_FAILOVER while the operation lasts"
  oc -n "$NS" patch configmap postgresql-role --type merge \
    -p '{"data":{"AUTO_FAILOVER":"false"}}' >/dev/null
fi

# --- 2) Declare the candidate (optimistic concurrency) ---------------------
echo "[1/5] ConfigMap postgresql-role: PRIMARY_POD=$CANDIDATE"
CM_RV="$(oc -n "$NS" get cm postgresql-role -o jsonpath='{.metadata.resourceVersion}')"
if ! set_cm_primary "$CANDIDATE" "$CM_RV"; then
  echo "ERROR: could not update the ConfigMap (did the role change?); aborting" >&2
  exit 1
fi

echo "[2/5] Services: -rw -> $CANDIDATE, -ro -> $OLD"
if ! set_services "$CANDIDATE" "$OLD"; then
  echo "ERROR: could not repoint the Services; reverting" >&2
  restore_state "$OLD" "$CANDIDATE" || echo "CRITICAL: inconsistent revert" >&2
  exit 1
fi

echo "[3/5] Fencing of the ex-primary $OLD"
FRC=0
fence_pod "$OLD" || FRC=$?
if [ "$FRC" -eq 1 ]; then
  echo "ERROR: could not confirm the isolation of $OLD (no changes); REVERTING" >&2
  restore_state "$OLD" "$CANDIDATE" || echo "CRITICAL: inconsistent revert" >&2
  exit 1
elif [ "$FRC" -eq 2 ]; then
  echo "CRITICAL: the delete of $OLD was accepted but its termination could not be confirmed." >&2
  echo "CRITICAL: it is NOT reverted (the pod may have been recreated as a replica). Intervention required." >&2
  exit 1
fi

echo "[4/5] Recreating pod $CANDIDATE so that it promotes"
oc -n "$NS" delete pod "$CANDIDATE" >/dev/null

echo "[5/5] Waiting for $CANDIDATE to become primary..."
OK=0
for _ in $(seq 1 60); do
  if [ "$(pod_in_recovery "$CANDIDATE")" = "f" ]; then OK=1; break; fi
  sleep 5
done

if [ "$OK" != "1" ]; then
  echo "CRITICAL: $CANDIDATE did not become primary (state: '$(pod_in_recovery "$CANDIDATE")')." >&2
  echo "CRITICAL: the ConfigMap already declares it primary and the ex-primary is isolated." >&2
  echo "CRITICAL: it is NOT reverted. Check the pods and finish the promotion by hand." >&2
  exit 1
fi

if [ "$AUTO_BEFORE" = "true" ]; then
  echo "      re-enabling AUTO_FAILOVER"
  oc -n "$NS" patch configmap postgresql-role --type merge \
    -p '{"data":{"AUTO_FAILOVER":"true"}}' >/dev/null
fi

echo
echo "Failover complete: primary=$CANDIDATE  replica=$OLD (re-seeds itself)"

echo "Verify with: ./scripts/verify-replication.sh"
