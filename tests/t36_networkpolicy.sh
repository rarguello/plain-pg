#!/usr/bin/env bash
# t36 -- Cross-namespace access: the NetworkPolicy only lets pods in plain-pg in,
#        and the documented namespaceSelector opens it for another namespace.
#        It creates and deletes its own throwaway namespace: the only test allowed
#        to touch a namespace other than plain-pg (AGENTS.md, rule 4).
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t36 cross-namespace access"

CLIENT_NS="plain-pg-client"
POLICY="postgresql-allow-client"
IMAGE="$(oc -n "$NS" get sts postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
HOST="postgresql-rw.$NS.svc.cluster.local"

cleanup() {
  oc delete namespace "$CLIENT_NS" --wait=false >/dev/null 2>&1 || true
  oc -n "$NS" delete networkpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "  (a client namespace, and a pod that runs psql against the Service)"
oc create namespace "$CLIENT_NS" >/dev/null 2>&1 || true
oc label namespace "$CLIENT_NS" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null
wait_for 60 "the client namespace is usable" \
  bash -c "oc -n $CLIENT_NS get serviceaccount default >/dev/null 2>&1"

# One shot per attempt: the same PostgreSQL image, which has psql. `timeout` is
# what matters: while the policy blocks the packets the connection hangs instead
# of failing.
client_query() {
  local job="$1"
  oc -n "$CLIENT_NS" delete job "$job" --ignore-not-found >/dev/null 2>&1
  # Do not hide this: a failed apply used to look like a timeout.
  if ! oc -n "$CLIENT_NS" apply -f - >/tmp/t36-apply.log 2>&1 <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 90
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: $IMAGE
          command: ["bash", "-c"]
          args: ["timeout 20 psql -h $HOST -U $APP_USER -d $APP_DB -tAc 'SELECT 1'"]
          env:
            - name: PGPASSWORD
              value: "$APP_PASSWORD"
EOF
  then
    echo "apply-failed: $(tail -1 /tmp/t36-apply.log)"
    return
  fi
  # wait_job_done (lib.sh) reads the job from $NS; this one lives elsewhere.
  local t=0 cond
  while [ "$t" -lt 180 ]; do
    cond="$(oc -n "$CLIENT_NS" get job "$job" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null || true)"
    case "$cond" in
      *Complete=True*) echo Complete; return 0 ;;
      *Failed=True*)   echo Failed;   return 0 ;;
    esac
    sleep 5; t=$((t + 5))
  done
  echo Timeout
}

check_eq "the other namespace is blocked by default" "Failed" "$(client_query blocked)"
check "nothing reached the database" bash -c \
  "! oc -n $CLIENT_NS logs job/blocked 2>/dev/null | grep -qx 1"

echo "  (opening it with the namespaceSelector from the docs)"
oc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $POLICY
  namespace: $NS
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
      app.kubernetes.io/instance: postgresql
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: $CLIENT_NS
      ports:
        - protocol: TCP
          port: 5432
EOF

check_eq "the same query completes once it is allowed" "Complete" "$(client_query allowed)"
check_contains "and it returned a row" "1" "$(oc -n "$CLIENT_NS" logs job/allowed 2>/dev/null)"

echo "  (removing the policy closes it again)"
oc -n "$NS" delete networkpolicy "$POLICY" >/dev/null 2>&1
check_eq "the namespace is blocked again" "Failed" "$(client_query blocked2)"

t_summary
