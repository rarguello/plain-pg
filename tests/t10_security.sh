#!/usr/bin/env bash
# t10 -- Security and cleanliness: non-root, SCC, minimal RBAC, no secrets in git.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t10 security and cleanliness"

PRIMARY="$(primary_pod)"

# Non-root
check_ne "the container does NOT run as root" "0" \
  "$(oc -n "$NS" exec "$PRIMARY" -- id -u 2>/dev/null)"

# PodSecurity restricted
SC="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].securityContext}')"
check_contains "allowPrivilegeEscalation=false" '"allowPrivilegeEscalation":false' "$SC"
check_contains "ALL capabilities are dropped" '"drop":["ALL"]' "$SC"
PSC="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.securityContext}')"
check_contains "seccompProfile RuntimeDefault" '"type":"RuntimeDefault"' "$PSC"
check_contains "runAsNonRoot=true" '"runAsNonRoot":true' "$PSC"

check_match "the pod received a restricted SCC" "restricted" \
  "$(oc -n "$NS" get pod "$PRIMARY" -o jsonpath='{.metadata.annotations.openshift\.io/scc}' 2>/dev/null)"
check_eq "the namespace enforces PodSecurity restricted" "restricted" \
  "$(oc get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)"

# Minimal RBAC for the failover controller
VERBS="$(oc -n "$NS" get role postgresql-failover -o jsonpath='{.rules[*].verbs}' 2>/dev/null)"
check_contains "the failover Role allows deleting pods" "delete" "$VERBS"
check "the Role does NOT allow creating pods" bash -c "! echo '$VERBS' | grep -qw create"
check "the Role is NOT a ClusterRole" bash -c "! oc get clusterrole postgresql-failover >/dev/null 2>&1"

# The CronJob pods must not collide with the Service selectors
CJ_LABELS="$(oc -n "$NS" get cronjob postgresql-failover -o jsonpath='{.spec.jobTemplate.spec.template.metadata.labels}')"
check "the CronJob labels do NOT include name=postgresql" \
  bash -c "! echo '$CJ_LABELS' | grep -q 'postgresql'"

# Secrets outside git
check "nothing inside secrets/ is versioned" \
  bash -c "! git -C '$ROOT_DIR' ls-files | grep -q '^secrets/'"
check "the real password is NOT versioned in git" \
  bash -c "! git -C '$ROOT_DIR' grep -qF '$APP_PASSWORD'"
check "the secrets/ directory is in .gitignore" \
  bash -c "git -C '$ROOT_DIR' check-ignore secrets/postgresql-credentials.env >/dev/null"

# The image is a Red Hat image
IMG="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
check_contains "the image comes from registry.redhat.io" "registry.redhat.io" "$IMG"
check "the docker.io/library/postgres image is not used" \
  bash -c "! git -C '$ROOT_DIR' grep -q 'docker.io/library/postgres' -- manifests/"

t_summary
