# Failover

El "primary" es el pod que dice la clave `PRIMARY_POD` del ConfigMap
`postgres-role`. Promover una réplica es cambiar ese valor y recrear los pods.

## Manual (el camino soportado)

```bash
./scripts/failover-manual.sh              # promueve la primera réplica
./scripts/failover-manual.sh postgres-1   # candidato explícito
```

El script hace, en este orden:

0. Desactiva el failover automático mientras dura la operación (para que el
   CronJob no interfiera) y lo reactiva al terminar.
1. `PRIMARY_POD=<candidato>` en el ConfigMap.
2. Reapunta los Services: `-rw` → candidato, `-ro` → ex-primary.
3. **Fencing del ex-primary**: lo borra y espera a confirmar que el objeto del
   pod cambió de UID (o desapareció). Si no lo puede confirmar, **revierte** el
   ConfigMap y los Services y no promueve.
4. Recrea el pod candidato: al arrancar ve que le toca ser primary, borra
   `standby.signal` y **promueve**.
5. Espera a confirmar. Si no promueve, **no** revierte al ex-primary (ya está
   aislado): deja el estado declarado en el candidato y falla fuerte para que
   intervenga una persona.

El fencing va **antes** de promover: así nunca hay dos primaries a la vez. El
ex-primary, al recrearse, se re-siembra solo desde el nuevo primary.

### A mano (equivalente)

```bash
NS=pg-ha-lab
oc -n $NS patch configmap postgres-role --type merge -p '{"data":{"PRIMARY_POD":"postgres-1"}}'
oc -n $NS patch svc postgres-rw -p '{"spec":{"selector":{"statefulset.kubernetes.io/pod-name":"postgres-1"}}}'
oc -n $NS patch svc postgres-ro -p '{"spec":{"selector":{"statefulset.kubernetes.io/pod-name":"postgres-0"}}}'
oc -n $NS delete pod postgres-1     # se promueve
oc -n $NS delete pod postgres-0     # se re-siembra como réplica
```

## Automático (opcional, *best-effort*)

`components/failover-automatico` agrega un CronJob que corre cada minuto:

1. Lee el rol declarado **fresco desde la API** (no de variables de entorno) y
   si el primary responde (`pg_is_in_recovery()` = `f`), no hace nada.
2. Si no responde, espera `FAILOVER_GRACE_SECONDS` (por defecto 120 s) por si es
   transitorio.
3. Elige una réplica sana (`pg_is_in_recovery()` = `t`).
4. Declara el candidato como primary y reapunta los Services.
5. **Fencing**: borra el ex-primary y espera a confirmar que su pod cambió de
   UID (o desapareció). Si no lo puede confirmar, **revierte** todo y no
   promueve.
6. Recrea el pod candidato para promoverlo y confirma. Si no promueve, no
   revierte (el ex-primary ya está aislado): falla fuerte.

Se configura en el ConfigMap `postgres-role`:

```bash
oc -n pg-ha-lab patch configmap postgres-role --type merge \
  -p '{"data":{"AUTO_FAILOVER":"true","FAILOVER_GRACE_SECONDS":"120"}}'
```

`AUTO_FAILOVER=false` lo desactiva sin borrar el CronJob (útil en
mantenimiento). El overlay `lab-manual` no lo incluye.

### Qué NO hace (leer antes de producción)

- **El fencing no es STONITH.** Se basa en que Kubernetes confirme la
  terminación del pod (cambio de UID). Si el **nodo** del ex-primary queda
  particionado del API server, el objeto del pod puede desaparecer al vencer el
  grace period aunque el contenedor siga vivo, y el fencing daría un falso
  positivo. Para producción, combinarlo con aislamiento a nivel de nodo
  (`MachineHealthCheck`, `fence_ack`, etc.).
- **La replicación es asíncrona**: un failover puede perder las últimas
  transacciones que no llegaron a replicarse. Si eso no es aceptable, activá
  replicación sincrónica (ver abajo): el commit espera a la réplica, con el
  costo de que si la réplica se cae, la escritura se bloquea.
- **La detección es por timeout**, no por consenso: con `GRACE` corto y un
  primary lento, puede promover de más. Un valor conservador (120–300 s) es
  sensato.
- **No reintenta más allá de lo descripto.** Si la promoción falla, queda el
  estado declarado en el candidato y hay que intervenir a mano.

### Replicación sincrónica (failover sin pérdida)

En el primary:

```sql
ALTER SYSTEM SET synchronous_standby_names = 'walreceiver';
SELECT pg_reload_conf();
```

Con `synchronous_commit = on` (default), cada commit espera a la réplica. Un
failover no pierde datos confirmados. **Trade-off:** si la réplica se cae, las
escrituras se bloquean hasta que vuelva (o hasta sacar el nombre de la lista).
