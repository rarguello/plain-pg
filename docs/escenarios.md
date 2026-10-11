# Escenarios: qué pasa si…

Esta matriz resume el comportamiento esperado. La batería de pruebas ejercita
casi todos estos casos (`docs/pruebas.md`).

| Escenario | Con failover manual | Con failover automático | Acción |
|---|---|---|---|
| Muere el proceso de PostgreSQL en el primary | El pod se reinicia y vuelve como primary. Corte de segundos. | Igual, **si** vuelve antes de `GRACE`. Si tarda más, promueve una réplica. | Ninguna si vuelve solo. |
| Se borra el pod del primary | K8s lo recrea con el mismo PVC; vuelve como primary. | Igual que arriba (el borrado no es una caída larga). | Ninguna. |
| Muere el pod de la réplica | K8s lo recrea; se reengancha al primary **sin** re-sembrar (conserva el PVC). | Igual. | Ninguna. |
| El primary queda inalcanzable (red) | La app no puede escribir. Hay que promover a mano. | Tras `GRACE`, aísla el ex-primary (fencing verificable), promueve la réplica y reapunta los Services. | Verificar que no haya dos primaries. |
| El **nodo** del primary se parte del API server | El pod sigue vivo, pero el API server puede terminarlo al vencer el grace period. | El fencing puede dar un falso positivo (no es STONITH). | Revisar el nodo antes de reincorporarlo. |
| La réplica se atrasó y el primary recicló WAL | Log: `requested WAL segment … has already been removed`. Replicación rota. | Igual (el failover no lo arregla). | `./scripts/reseed-replica.sh postgres-1` |
| Se corrompe el PVC del primary | Promover la réplica; el ex-primary se re-siembra desde cero. | Igual, automático. | Verificar que los datos estén completos; restaurar backup si falta algo. |
| Se borra el PVC de la réplica | Al recrearse, `PGDATA` vacío → `pg_basebackup` completo. | Igual. | Ninguna. |
| Se llena el disco del PVC de datos | PostgreSQL pasa a solo lectura y deja de aceptar escrituras. | El primary sigue "respondiendo", así que **no** hay failover. | Liberar espacio / re-sembrar. Los backups viven en otro PVC. |
| Se rota el password de replicación | Hay que regenerar el Secret y recrear los pods. | Igual. | `scripts/generate-secret.sh` + borrar los pods. |
| Se hace `oc adm drain` del nodo del primary | El pod se reprograma; la app tiene un corte. | Idem. | Ninguna (clusters multi-nodo). |
| Se escala a 3 pods | `postgres-2` se siembra desde el primary y replica. `-ro` **no** lo incluye. | Igual. | Usar el DNS del pod o ampliar el selector de `-ro`. |
| Se escala de 3 a 2 | Se elimina `postgres-2`; su PVC queda huérfano. | Igual. | `oc delete pvc pgdata-postgres-2` |
| Un `oc apply` de los manifiestos | No reinicia la base (`OnDelete`). | Igual. | Borrar pods a mano para aplicar cambios de template. |
| Se borra el Secret | Los pods nuevos no arrancan (`CreateContainerConfigError`). | El CronJob tampoco corre. | Regenerar el Secret. |
| Se pierde el nodo entero (cluster SNO) | Todo cae; al volver el nodo, los pods arrancan con sus PVCs. | Igual. | Ninguna. |

## Casos que necesitan intervención humana

- **El nodo del primary particionado del API server**: el fencing puede dar un
  falso positivo. Revisar que no queden dos primaries antes de devolver el
  ex-primary al servicio.
- **Pérdida del PVC del primary y de la réplica a la vez**: sólo queda el backup.
  `./scripts/restore-backup.sh`.
- **Divergencia de datos tras un failover asíncrono**: el ex-primary se
  re-siembra y lo no replicado se pierde. Para evitarlo, replicación sincrónica
  ([failover.md](failover.md)).
- **Promoción fallida**: el estado declarado queda en el candidato y el
  ex-primary aislado. Terminar la promoción a mano
  (`oc -n pg-ha-lab delete pod <candidato>`) o volver atrás explícitamente.
