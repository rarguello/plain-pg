# pg-ha

**PostgreSQL con una réplica en OpenShift, usando solo objetos nativos de
Kubernetes. Sin operadores, sin CRDs, sin consolas.**

*PostgreSQL streaming replication on OpenShift with plain Kubernetes objects —
no operator, no CRD.*

Un StatefulSet de 2 pods: `postgres-0` es el primary y `postgres-1` una réplica
hot standby. La imagen es **PostgreSQL 18 sobre UBI** (`registry.redhat.io/rhel10/postgresql-18`).
El rol de cada pod se decide con un ConfigMap, así que promover una réplica es
cambiar un valor y recrear pods — no hace falta un controlador.

```
                 ┌─────────────────────────── Namespace: pg-ha-lab ───────────────────────────┐
                 │                                                                            │
  apps ──rw─────▶│  Service postgres-rw ──▶ pod postgres-0  [PRIMARY]  ──▶ PVC pgdata-…-0     │
                 │                                    │  WAL streaming                       │
  apps ──ro─────▶│  Service postgres-ro ──▶ pod postgres-1  [STANDBY]  ──▶ PVC pgdata-…-1     │
                 │                                    ▲                                     │
                 │  Service postgres-hl (headless) ───┘  DNS estable por pod                  │
                 │                                                                            │
                 │  CronJob postgres-backup   → pg_dump  → PVC postgres-backups               │
                 │  CronJob postgres-failover → promueve si el primary no responde (opcional)  │
                 └────────────────────────────────────────────────────────────────────────────┘
```

## Qué es

- Replicación streaming nativa de PostgreSQL, configurada por scripts.
- Reutiliza la maquinaria de la imagen de Red Hat (`run-postgresql`, hooks,
  `ENABLE_REPLICATION`): no reimplementa `initdb` ni la creación de usuarios.
- Tres Services: `-rw` (primary), `-ro` (réplica), `-hl` (DNS entre pods).
- **Failover manual** documentado y **failover automático opcional** (un CronJob
  que revisa el primary y promueve una réplica).
- **Backups lógicos** (`pg_dump`/`pg_dumpall`) con retención, en un CronJob.
- Despliegue con **Kustomize** y una **batería de pruebas** que se corre contra
  un cluster real.

## Qué NO es

- **No es un operador.** No hay CRDs, no hay reconciliación continua, no hay
  consola. Si necesitás eso, usá [CloudNativePG](https://cloudnative-pg.io/),
  [Zalando](https://github.com/zalando/postgres-operator) o
  [Crunchy](https://access.crunchydata.com/documentation/postgres-operator/latest/).
  Ver [docs/comparacion.md](docs/comparacion.md).
- **No es PITR.** Los backups son lógicos (dumps), no hay archivado de WAL.
- **El failover automático no es HA de nivel producción.** Hace *fencing*
  verificable a nivel de pod (borra el ex-primary y confirma que terminó) antes
  de promover, pero no es STONITH: si el nodo se parte del API server puede dar
  un falso positivo. La replicación es asíncrona, así que un failover puede
  perder las últimas transacciones no replicadas. Leé
  [docs/failover.md](docs/failover.md) antes de usarlo en producción.
- **No resuelve la elección de líder** (quórum/consenso). El "primary" es el que
  dice el ConfigMap.

## Inicio rápido

Requisitos: `oc` (o `kubectl`) logueado en el cluster y `git`. Nada más.

```bash
git clone https://github.com/<tu-usuario>/pg-ha.git && cd pg-ha

./scripts/deploy.sh              # despliega el overlay completo (con failover automático)
./scripts/verify-replication.sh  # verifica que la réplica está al día
```

También hay `make`:

```bash
make deploy      # desplegar
make verify      # verificar la replicación
make lint        # shellcheck + kustomize + scripts embebidos
make test-quick  # pruebas no destructivas
```

Si preferís solo replicación + failover manual (sin el CronJob de failover):

```bash
./scripts/deploy.sh manifests/overlays/lab-manual
```

Para destruir el laboratorio:

```bash
./scripts/teardown.sh        # borra recursos, PVCs y el Secret
./scripts/teardown.sh --all  # borra el namespace completo
```

## Uso

```bash
# Lectura/escritura -> siempre el primary
psql "postgresql://app:PASS@postgres-rw.pg-ha-lab.svc:5432/appdb"

# Solo lectura -> la réplica
psql "postgresql://app:PASS@postgres-ro.pg-ha-lab.svc:5432/appdb"

# Estado de la replicación
oc -n pg-ha-lab exec postgres-0 -- psql -U postgres -c 'SELECT * FROM pg_stat_replication;'

# Backup manual / restore a una base nueva
./scripts/backup-now.sh
./scripts/restore-backup.sh /backups/<archivo>.dump mi_base_restaurada

# Failover manual
./scripts/failover-manual.sh
```

## Documentación

| Documento | Contenido |
|---|---|
| [docs/arquitectura.md](docs/arquitectura.md) | Cómo funciona por dentro y por qué |
| [docs/operacion.md](docs/operacion.md) | Desplegar, verificar, tareas del día a día |
| [docs/failover.md](docs/failover.md) | Failover manual y automático, límites |
| [docs/backups.md](docs/backups.md) | Backups, retención y restore |
| [docs/escenarios.md](docs/escenarios.md) | Matriz "qué pasa si…" |
| [docs/comparacion.md](docs/comparacion.md) | Comparación honesta con CloudNativePG |
| [docs/pruebas.md](docs/pruebas.md) | Cómo correr la batería de pruebas y resultados |
| [docs/notas-tecnicas.md](docs/notas-tecnicas.md) | Detalles finos (digest multi-arch, `oc apply`, etc.) |

## Estructura

```
manifests/
  base/                 objetos comunes (kustomize)
  components/           add-ons opcionales (failover automático)
  overlays/lab/         despliegue completo   (pg-ha-lab)
  overlays/lab-manual/  solo failover manual
scripts/                deploy, teardown, verify, failover, backup, restore
tests/                  batería de pruebas (t01…t20) + runner
tools/                  validación estática (scripts embebidos)
docs/                   documentación
```

## Licencia

MIT. Ver [LICENSE](LICENSE).
