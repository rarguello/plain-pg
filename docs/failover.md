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

Mismo orden que el script: **fencing antes de promover**. Si en el paso 3 no se
confirma que el ex-primary terminó, **no se promueve**.

```bash
NS=pg-ha-lab
OLD=postgres-0     # primary actual
NEW=postgres-1     # candidato

# 0. Desactivar el failover automático mientras dura la operación
oc -n $NS patch configmap postgres-role --type merge -p '{"data":{"AUTO_FAILOVER":"false"}}'

# 1. Declarar el candidato como primary
oc -n $NS patch configmap postgres-role --type merge -p "{\"data\":{\"PRIMARY_POD\":\"$NEW\"}}"

# 2. Reapuntar los Services
oc -n $NS patch svc postgres-rw -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$NEW\"}}}"
oc -n $NS patch svc postgres-ro -p "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"$OLD\"}}}"

# 3. FENCING: borrar el ex-primary y CONFIRMAR que terminó
oc -n $NS get pod $OLD -o jsonpath='{.metadata.uid}'; echo   # anotar el UID
oc -n $NS delete pod $OLD
#   esperar y volver a consultar el UID: debe ser DISTINTO, o el pod no existir.
#   Si el UID no cambia, NO seguir: el primary anterior sigue vivo.

# 4. Promover el candidato
oc -n $NS delete pod $NEW
oc -n $NS exec $NEW -- psql -U postgres -tAc 'SELECT pg_is_in_recovery();'  # debe dar f

# 5. Reactivar el automático
oc -n $NS patch configmap postgres-role --type merge -p '{"data":{"AUTO_FAILOVER":"true"}}'
```

Es fácil equivocarse a mano (sobre todo en el paso 3). El script
`failover-manual.sh` hace exactamente esto, con verificación de cada paso y
reversión si algo falla: usalo salvo que no tengas otra opción.

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

- **El fencing no es STONITH: no garantiza que el proceso viejo esté muerto.**
  Se basa en que Kubernetes confirme la terminación del pod (el objeto
  desaparece o cambia de UID). Si el **nodo** del ex-primary queda particionado
  del API server, el objeto del pod puede desaparecer al vencer el grace period
  aunque el contenedor siga ejecutándose: el fencing daría un falso positivo y
  podrían quedar dos primaries (split-brain).

  **Consecuencia práctica:** mientras no haya fencing externo del nodo, el
  failover automático es aceptable para un laboratorio o para escenarios donde
  la caída es del pod (no del nodo). Para producción con garantía real:
  - habilitá aislamiento a nivel de nodo (por ejemplo `MachineHealthCheck` +
    `fence_ack`, o el mecanismo del proveedor de infraestructura) antes de
    confiar en el failover automático; o
  - dejá `AUTO_FAILOVER=false` y operá el failover manual, donde una persona
    puede verificar que el nodo/primary anterior está realmente fuera.

  El repo **no** afirma aislamiento físico del primary anterior: sólo verifica
  el pod.
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
