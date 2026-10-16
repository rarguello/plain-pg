#!/usr/bin/env bash
# t17 -- The AUTO_FAILOVER=false switch disables automatic failover: if the
#        primary becomes unreachable, the role does NOT change.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t17 AUTO_FAILOVER=false does not trigger failover"

PRIMARY="$(primary_pod)"

oc -n "$NS" patch cm postgresql-role --type merge \
  -p '{"data":{"AUTO_FAILOVER":"false","FAILOVER_GRACE_SECONDS":"15"}}' >/dev/null

# Isolate the primary from the controller (same simulation as t08)
oc -n "$NS" delete networkpolicy postgresql-ingress --ignore-not-found >/dev/null 2>&1
oc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: test-isolate-primary
  namespace: $NS
spec:
  podSelector:
    matchLabels:
      statefulset.kubernetes.io/pod-name: $PRIMARY
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: postgresql
              app.kubernetes.io/component: database
      ports: [{protocol: TCP, port: 5432}]
EOF

echo "  (waiting 100s: the controller must NOT promote anything)"
sleep 100
check_eq "the role did NOT change with AUTO_FAILOVER=false" "$PRIMARY" "$(primary_pod)"

# The controller must have logged that it is disabled
LOG="$(oc -n "$NS" logs -l app.kubernetes.io/component=failover --tail=20 2>/dev/null || true)"
check_contains "the controller logs that auto-failover is disabled" \
  "auto-failover disabled" "$LOG"

# Restore
oc -n "$NS" delete networkpolicy test-isolate-primary --ignore-not-found >/dev/null 2>&1
oc -n "$NS" apply -k "$ROOT_DIR/manifests/overlays/ha" >/dev/null 2>&1
check_eq "AUTO_FAILOVER is true again" "true" "$(cm_value AUTO_FAILOVER)"
check_eq "the primary is still $PRIMARY" "$PRIMARY" "$(primary_pod)"

t_summary
