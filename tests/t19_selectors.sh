#!/usr/bin/env bash
# t19 -- Regression: the auxiliary pods (backup, failover) must NOT collide with
#        the PostgreSQL Service selectors.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

echo "### t19 selectors and labels (regression)"

# No label of the auxiliary pods may match the DB selectors
for cj in postgresql-failover postgresql-backup; do
  L="$(oc -n "$NS" get cronjob "$cj" -o jsonpath='{.spec.jobTemplate.spec.template.metadata.labels}' 2>/dev/null)"
  check "the labels of CronJob $cj do not say name=postgresql" \
    bash -c "! echo '$L' | grep -q '\"app.kubernetes.io/name\":\"postgresql\"'"
  check "the labels of CronJob $cj do not say instance=postgresql" \
    bash -c "! echo '$L' | grep -q '\"app.kubernetes.io/instance\":\"postgresql\"'"
done

# postgresql-hl must only have the DB pods
HL="$(oc -n "$NS" get endpoints postgresql-hl -o jsonpath='{range .subsets[*].addresses[*]}{.targetRef.name}{"\n"}{end}' 2>/dev/null | sort | tr '\n' ' ')"
DB="$(db_pods | tr '\n' ' ')"
check_eq "postgresql-hl contains exactly the DB pods" "$DB" "$HL"

# -rw and -ro select by pod name (not by dynamic role)
check_eq "postgresql-rw selects by pod-name" "postgresql-0" \
  "$(oc -n "$NS" get svc postgresql-rw -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"
check_eq "postgresql-ro selects by pod-name" "postgresql-1" \
  "$(oc -n "$NS" get svc postgresql-ro -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}' 2>/dev/null)"

# The headless service publishes not-ready pod addresses (needed for startup)
check_eq "postgresql-hl publishes not-ready pods" "true" \
  "$(oc -n "$NS" get svc postgresql-hl -o jsonpath='{.spec.publishNotReadyAddresses}' 2>/dev/null)"

t_summary
