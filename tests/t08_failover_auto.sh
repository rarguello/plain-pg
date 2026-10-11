#!/usr/bin/env bash
# t08 -- AUTOMATIC failover: the CronJob promotes a replica when the declared
#        primary becomes unreachable. It restores the state at the end.
#
# Simulation: the NetworkPolicy is temporarily replaced by two policies that
# make the primary UNREACHABLE for the controller (but not for the DB
# replicas). It is deterministic and reversible.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t08 automatic failover"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
streaming() { [ "$(streaming_count "$1")" = "1" ]; }

echo "  primary=$PRIMARY replica=$REPLICA"

# --- prepare: short grace period to speed up the test ---
oc -n "$NS" patch cm postgresql-role --type merge \
  -p '{"data":{"AUTO_FAILOVER":"true","FAILOVER_GRACE_SECONDS":"15"}}' >/dev/null

# --- isolate the primary from the controller ---
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
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: test-allow-rest
  namespace: $NS
spec:
  podSelector:
    matchLabels:
      statefulset.kubernetes.io/pod-name: $REPLICA
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
      ports: [{protocol: TCP, port: 5432}]
EOF

# --- wait for the automatic failover ---
failover_happened() { [ "$(primary_pod)" != "$PRIMARY" ]; }
wait_for 420 "the CronJob detects the failure and fails over" failover_happened

NEW="$(primary_pod)"
check_ne "the declared primary changed" "$PRIMARY" "$NEW"
check_eq "the new primary is the healthy replica ($REPLICA)" "$REPLICA" "$NEW"

# The controller changes the role and then promotes (asynchronous): you have to
# wait for the pod to finish promoting.
is_primary() { [ "$(pod_in_recovery "$1")" = "f" ]; }
is_standby() { [ "$(pod_in_recovery "$1")" = "t" ]; }
wait_for 300 "$REPLICA finishes promoting" is_primary "$REPLICA"
wait_for 300 "$PRIMARY re-seeds as a replica" is_standby "$PRIMARY"
wait_for 180 "replication runs in the new direction" streaming "$REPLICA"

IP_NEW="$(oc -n "$NS" get pod "$REPLICA" -o jsonpath='{.status.podIP}')"
check_eq "postgresql-rw was repointed automatically" "$IP_NEW" \
  "$(oc -n "$NS" get endpoints postgresql-rw -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"

# --- clean up the simulation ---
oc -n "$NS" delete networkpolicy test-isolate-primary test-allow-rest --ignore-not-found >/dev/null 2>&1
oc apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgresql-ingress
  labels:
    app.kubernetes.io/name: postgresql
    app.kubernetes.io/instance: postgresql
    app.kubernetes.io/part-of: plain-pg
    app.kubernetes.io/component: database
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
      app.kubernetes.io/instance: postgresql
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
      ports: [{protocol: TCP, port: 5432}]
EOF

# --- restore the original state ---
echo "  (failback to $PRIMARY and configuration restore)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$PRIMARY" || c_fail "the failback failed"
check_eq "the ConfigMap declares $PRIMARY again" "$PRIMARY" "$(primary_pod)"
wait_for 300 "$PRIMARY is primary again" is_primary "$PRIMARY"
wait_for 300 "$REPLICA is standby again" is_standby "$REPLICA"
wait_for 180 "replication re-established" streaming "$PRIMARY"

oc -n "$NS" apply -k "$ROOT_DIR/manifests/overlays/lab" >/dev/null 2>&1
check_eq "FAILOVER_GRACE_SECONDS restored to 120" "120" "$(cm_value FAILOVER_GRACE_SECONDS)"

t_summary
