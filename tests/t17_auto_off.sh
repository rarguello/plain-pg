#!/usr/bin/env bash
# t17 -- El interruptor AUTO_FAILOVER=false desactiva el failover automatico:
#        si el primary queda inalcanzable, el rol NO cambia.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t17 AUTO_FAILOVER=false no dispara failover"

PRIMARY="$(primary_pod)"

oc -n "$NS" patch cm postgres-role --type merge \
  -p '{"data":{"AUTO_FAILOVER":"false","FAILOVER_GRACE_SECONDS":"15"}}' >/dev/null

# Aislar el primary del controlador (misma simulacion que t08)
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
EOF

echo "  (esperando 100s: el controlador NO debe promover nada)"
sleep 100
check_eq "el rol NO cambio con AUTO_FAILOVER=false" "$PRIMARY" "$(primary_pod)"

# El controlador debe haber registrado que esta deshabilitado
LOG="$(oc -n "$NS" logs -l app.kubernetes.io/component=failover --tail=20 2>/dev/null || true)"
check_contains "el controlador registra que el auto-failover esta deshabilitado" \
  "auto-failover deshabilitado" "$LOG"

# Restaurar
oc -n "$NS" delete networkpolicy test-isolate-primary --ignore-not-found >/dev/null 2>&1
oc -n "$NS" apply -k "$ROOT_DIR/manifests/overlays/lab" >/dev/null 2>&1
check_eq "AUTO_FAILOVER vuelve a true" "true" "$(cm_value AUTO_FAILOVER)"
check_eq "el primary sigue siendo $PRIMARY" "$PRIMARY" "$(primary_pod)"

t_summary
