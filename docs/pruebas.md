# Pruebas

La batería corre **contra un cluster real** (no hay mocks). Cada test imprime
`[PASS]`/`[FAIL]` por comprobación y devuelve un código de salida.

## Cómo correrlas

```bash
./tests/run-all.sh              # todas (incluye destructivas: failover, teardown)
./tests/run-all.sh rapido       # solo las no destructivas
./tests/run-all.sh t03 t04      # pruebas puntuales
```

Las destructivas (t07, t08, t11, t13, t15, t16, t17) cambian el estado del
cluster, pero **dejan el sistema consistente al terminar**. La t11 borra los PVCs
y vuelve a desplegar desde cero.

## Qué cubre cada test

| Test | Cubre |
|---|---|
| `t01_despliegue` | Objetos, PVCs, pods listos, imagen UBI + PG18 por digest |
| `t02_roles` | Quién es primary/réplica y su coherencia en disco (`standby.signal`, `primary_conninfo`) |
| `t03_replicacion` | Streaming, lag 0, escritura→lectura entre pods, réplica read-only |
| `t04_servicios` | Endpoints de `-rw`/`-ro`/`-hl`, DNS y conexión por los Services |
| `t05_config` | `wal_level`, `max_wal_senders`, `hot_standby`, `pg_hba`, usuario de replicación, base y usuario de la app |
| `t06_persistencia` | Reiniciar la réplica no re-siembra; reiniciar el primary no pierde datos; la replicación se reanuda |
| `t07_failover_manual` | Failover manual completo **y failback**, con verificación de datos y Services |
| `t08_failover_automatico` | El CronJob detecta el primary inalcanzable y promueve; luego restaura |
| `t09_idempotencia` | Re-aplicar no cambia objetos (resourceVersion), render estable, `deploy.sh` re-ejecutable |
| `t10_seguridad` | Non-root, PodSecurity `restricted`, RBAC mínimo, sin secretos en git |
| `t11_teardown` | Teardown borra todo y el re-despliegue queda sano |
| `t12_backup` | Backup manual válido y **restore verificado** en una base nueva |
| `t13_escalado` | Escalar a 3 réplicas (se siembra y replica) y volver a 2 |
| `t14_integridad` | 5000 filas: checksum idéntico en primary y réplica, lag 0 |
| `t15_reseed` | `reseed-replica.sh` recrea el PVC y vuelve a sembrar |
| `t16_failover_carga` | Failover con escritor activo: los datos confirmados **antes** del failover sobreviven, se acota la pérdida por la ventana asíncrona, y al terminar hay un solo primary |
| `t17_auto_off` | `AUTO_FAILOVER=false` **no** dispara failover |
| `t18_imagen` | El digest fijado coincide con el del registro y con el de los pods |
| `t19_selectores` | Regresión: los pods auxiliares no colisionan con los selectores de los Services |
| `t20_reinicio_total` | Tras un failover, recrear **los dos** pods a la vez deja los roles correctos (sin deadlock de `Parallel`) |
| `t21_seguridad_pg` | El usuario de la app no es superusuario; la réplica rechaza DDL; desde otro pod la password es obligatoria |

## Requisitos

- `oc` (o `kubectl`) logueado, con permiso para crear namespaces.
- `skopeo` y `~/.pull-secret.json` para `t18` (si no están, ese test se saltea).
- StorageClass por defecto con `WaitForFirstConsumer` (para que el PVC de backup
  se ligue al primer uso).

## Validación estática (sin cluster)

Antes de correr nada contra un cluster, se puede validar la sintaxis de los
scripts embebidos en los ConfigMaps y el render de kustomize:

```bash
oc kustomize manifests/overlays/lab > /tmp/lab.yaml
oc kustomize manifests/overlays/lab-manual > /tmp/lab-manual.yaml
tools/check-scripts.py /tmp/lab.yaml /tmp/lab-manual.yaml
shellcheck -S warning scripts/*.sh tests/*.sh
```

Eso es lo que corre el CI (`.github/workflows/lint.yml`) en cada push.

## Resultados

Última corrida completa en el laboratorio (OpenShift 4.21, SNO
`sno.virt.daytwo.dev`): **21/21 tests, 214 comprobaciones, 0 fallos, ~15 min.**

| Test | PASS |
|---|---|
| t01 despliegue | 29 |
| t02 roles | 11 |
| t03 replicación | 7 |
| t04 services | 8 |
| t05 config | 13 |
| t06 persistencia | 11 |
| t07 failover manual (ida y vuelta) | 18 |
| t08 failover automático | 12 |
| t09 idempotencia | 4 |
| t10 seguridad | 16 |
| t11 teardown y re-despliegue | 11 |
| t12 backups y restore | 11 |
| t13 escalado | 8 |
| t14 integridad | 4 |
| t15 re-siembra | 7 |
| t16 failover bajo carga | 9 |
| t17 auto-failover desactivado | 4 |
| t18 imagen y digest | 7 |
| t19 selectores (regresión) | 8 |
| t20 reinicio total tras failover | 9 |
| t21 seguridad PostgreSQL | 7 |

Salida completa: [`evidencia/2026-10-11-suite-completa.txt`](evidencia/2026-10-11-suite-completa.txt).
