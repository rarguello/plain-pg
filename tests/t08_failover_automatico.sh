#!/usr/bin/env bash
# t08 -- Failover AUTOMATICO: el CronJob promueve una replica cuando el primary
#        declarado queda inalcanzable. Al final restaura el estado.
#
# Simulacion: se reemplaza temporalmente la NetworkPolicy por dos politicas que
# dejan al primary INALCANZABLE para el controlador (pero no para las replicas
# de la BD). Es deterministico y reversible.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t08 failover automatico"

PRIMARY="$(primary_pod)"
REPLICA="$(replica_pods | head -1)"
streaming() { [ "$(streaming_count "$1")" = "1" ]; }

echo "  primary=$PRIMARY replica=$REPLICA"

# --- preparar: gracia corta para acelerar la prueba ---
oc -n "$NS" patch cm postgres-role --type merge \
  -p '{"data":{"AUTO_FAILOVER":"true","FAILOVER_GRACE_SECONDS":"15"}}' >/dev/null

# --- aislar el primary del controlador ---
oc -n "$NS" delete networkpolicy postgres-ingress --ignore-not-found >/dev/null 2>&1
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

# --- esperar el failover automatico ---
failover_happened() { [ "$(primary_pod)" != "$PRIMARY" ]; }
wait_for 420 "el CronJob detecta la caida y hace failover" failover_happened

NEW="$(primary_pod)"
check_ne "el primary declarado cambio" "$PRIMARY" "$NEW"
check_eq "el nuevo primary es la replica sana ($REPLICA)" "$REPLICA" "$NEW"
check_eq "$REPLICA es primary" "f" "$(pod_in_recovery "$REPLICA")"
wait_for 300 "$PRIMARY se re-siembra como replica" bash -c "[ \"\$(oc -n $NS get pod $PRIMARY -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$PRIMARY quedo como standby" "t" "$(pod_in_recovery "$PRIMARY")"
wait_for 180 "la replicacion corre en el nuevo sentido" streaming "$REPLICA"

IP_NEW="$(oc -n "$NS" get pod "$REPLICA" -o jsonpath='{.status.podIP}')"
check_eq "postgres-rw fue reapuntado automaticamente" "$IP_NEW" \
  "$(oc -n "$NS" get endpoints postgres-rw -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"

# --- limpiar la simulacion ---
oc -n "$NS" delete networkpolicy test-isolate-primary test-allow-rest --ignore-not-found >/dev/null 2>&1
oc apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-ingress
  labels:
    app.kubernetes.io/name: postgresql
    app.kubernetes.io/instance: postgres
    app.kubernetes.io/part-of: pg-ha
    app.kubernetes.io/component: database
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
      app.kubernetes.io/instance: postgres
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
      ports: [{protocol: TCP, port: 5432}]
EOF

# --- restaurar el estado original ---
echo "  (failback a $PRIMARY y restauracion de la configuracion)"
FORCE=1 "$ROOT_DIR/scripts/failover-manual.sh" "$PRIMARY" || c_fail "el failback fallo"
check_eq "el ConfigMap vuelve a declarar $PRIMARY" "$PRIMARY" "$(primary_pod)"
check_eq "$PRIMARY vuelve a ser primary" "f" "$(pod_in_recovery "$PRIMARY")"
wait_for 300 "$REPLICA vuelve a ser standby" bash -c "[ \"\$(oc -n $NS get pod $REPLICA -o jsonpath='{.status.containerStatuses[0].ready}')\" = true ]"
check_eq "$REPLICA vuelve a ser standby" "t" "$(pod_in_recovery "$REPLICA")"
wait_for 180 "replicacion restablecida" streaming "$PRIMARY"

oc -n "$NS" apply -k "$ROOT_DIR/manifests/overlays/lab" >/dev/null 2>&1
check_eq "FAILOVER_GRACE_SECONDS restaurado a 120" "120" "$(cm_value FAILOVER_GRACE_SECONDS)"

t_summary
