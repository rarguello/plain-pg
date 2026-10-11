# Operación

## Desplegar

```bash
./scripts/deploy.sh                            # completo (con failover automático)
./scripts/deploy.sh manifests/overlays/lab-manual   # solo failover manual
```

`deploy.sh` aplica el overlay con Kustomize, genera el Secret (con passwords
aleatorios, fuera de git) y espera a que los pods queden listos. Es idempotente.

## Verificar

```bash
./scripts/verify-replication.sh
```

Hace, en orden: comprueba los roles, muestra `pg_stat_replication`, verifica el
lag, y escribe una fila en el primary para leerla desde la réplica.

A mano:

```bash
oc -n pg-ha-lab get pods,pvc,svc
oc -n pg-ha-lab exec postgres-0 -- psql -U postgres -c 'SELECT * FROM pg_stat_replication;'
oc -n pg-ha-lab exec postgres-1 -- psql -U postgres -c 'SELECT pg_is_in_recovery();'   # t = réplica
```

## Conectarse

Las credenciales quedan en `secrets/postgres-credentials.env` (no versionado).

```bash
NS=pg-ha-lab
# usuario de la app (lectura/escritura)
oc -n $NS exec -it postgres-0 -- psql -h postgres-rw -U app -d appdb
# usuario de la app (solo lectura)
oc -n $NS exec -it postgres-1 -- psql -h postgres-ro -U app -d appdb
# superusuario
oc -n $NS exec -it postgres-0 -- psql -h 127.0.0.1 -U postgres
```

## Tareas frecuentes

```bash
# Logs
oc -n pg-ha-lab logs -f postgres-0
oc -n pg-ha-lab logs -f postgres-1

# Reiniciar la réplica (sin impacto en la app)
oc -n pg-ha-lab delete pod postgres-1        # se recrea y reengancha

# Reiniciar el primary (corte breve)
oc -n pg-ha-lab delete pod postgres-0

# Medir el lag de la réplica
oc -n pg-ha-lab exec postgres-0 -- psql -U postgres -tAc \
  "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) FROM pg_stat_replication;"

# Agregar una réplica (2 -> 3 pods)
oc -n pg-ha-lab scale statefulset postgres --replicas=3

# Volver a 2 (el PVC del pod eliminado queda huérfano; borralo si no lo querés)
oc -n pg-ha-lab scale statefulset postgres --replicas=2
oc -n pg-ha-lab delete pvc pgdata-postgres-2

# Re-sembrar una réplica rota (la vuelve a copiar desde el primary)
./scripts/reseed-replica.sh postgres-1
```

## Si la réplica se atrasó demasiado

Con replicación asíncrona y sin slots, el primary puede reciclar WAL que la
réplica necesitaba (aviso en los logs: `requested WAL segment … has already been
removed`). Se arregla re-sembrando:

```bash
./scripts/reseed-replica.sh postgres-1
```

## Mantenimiento de un nodo

```bash
oc adm drain <nodo> --ignore-daemonsets --delete-emptydir-data
```

El pod del primary se reprograma (corte de segundos a minutos); la réplica se
reengancha sola cuando el primary vuelve.

## Notas

- El StatefulSet usa `updateStrategy: OnDelete`: cambiar el template no reinicia
  nada. Para aplicar un cambio, borrá los pods a mano (`postgres-1` primero, si
  querés cero downtime).
- Un `oc apply` de los manifiestos **no** toca el Secret: se administra con
  `scripts/generate-secret.sh`.
