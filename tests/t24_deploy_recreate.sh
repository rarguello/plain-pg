#!/usr/bin/env bash
# t24 -- deploy.sh can recreate a MISSING StatefulSet with the right replica
#        count. Regression: it used to abort (a `oc get sts` under `set -e`), and
#        the "existing deployment" path strips spec.replicas, so a recreated
#        StatefulSet was created without it and the API defaulted it to 1.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t24 deploy.sh recreates a missing StatefulSet"

# This test deletes the StatefulSet (the pods go with it and the replica
# re-seeds itself from its PVC). Destructive: full-suite only.
check "the role ConfigMap exists" oc -n "$NS" get cm postgresql-role
check_eq "the StatefulSet starts at 2 replicas" "2" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}' 2>/dev/null)"
PRIMARY_BEFORE="$(primary_pod)"
echo "  starting state: primary=$PRIMARY_BEFORE replicas=2"

echo "  (deleting the StatefulSet, keeping the ConfigMap and the Services)"
oc -n "$NS" delete sts postgresql --ignore-not-found >/dev/null 2>&1
check "the StatefulSet is gone" bash -c "! oc -n $NS get sts postgresql >/dev/null 2>&1"

# deploy.sh must recreate it (not abort) and with the overlay's count (2), not
# the API default (1).
check "deploy.sh recreates it and waits for the pods" \
  env NAMESPACE="$NS" "$ROOT_DIR/scripts/deploy.sh"
check_eq "the recreated StatefulSet has 2 replicas" "2" \
  "$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.replicas}' 2>/dev/null)"
# Regression: a second apply must not prune spec.replicas. Server-side apply
# drops a field its manager no longer sets, and the API re-defaults it to 1.
check "a second deploy keeps 2 replicas" bash -c \
  "env NAMESPACE='$NS' '$ROOT_DIR/scripts/deploy.sh' >/dev/null 2>&1 && \
   [ \"\$(oc -n '$NS' get sts postgresql -o jsonpath='{.spec.replicas}')\" = '2' ]"
check_eq "the declared primary is unchanged" "$PRIMARY_BEFORE" "$(primary_pod)"
wait_for 300 "the two pods are Ready again" wait_db_ready 2
check_eq "the declared primary is primary again" "f" "$(pod_in_recovery "$PRIMARY_BEFORE")"
check_eq "the other pod is a standby again" "t" "$(pod_in_recovery "$(replica_pods | head -1)")"

t_summary
