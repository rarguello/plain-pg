# AGENTS.md — Reglas del proyecto `pg-ha`

Guía para cualquier agente (OpenCode, Codex) o persona que toque este repo.

## Qué es

Replicación streaming de PostgreSQL en OpenShift con **objetos nativos de
Kubernetes**. Sin operadores, sin CRDs, sin consolas.

- 1 primary (`postgres-0`) + 1 réplica hot standby (`postgres-1`).
- Imagen **PostgreSQL 18 sobre UBI** (`registry.redhat.io/rhel10/postgresql-18`),
  fijada por digest.
- El rol lo decide el ConfigMap `postgres-role` (clave `PRIMARY_POD`).
- Failover manual documentado + failover automático opcional (CronJob) con
  fencing verificable a nivel de pod.
- Backups lógicos con `pg_dump` en un CronJob.
- Despliegue con Kustomize; batería de pruebas en `tests/`.

## Reglas duras

1. **Nada de operadores ni CRDs.** Sólo objetos core.
2. **Nada de secretos en git.** El Secret se genera con
   `scripts/generate-secret.sh` y vive en `secrets/` (ignorado).
3. **La imagen debe ser UBI** (`registry.redhat.io/...`), fijada por digest.
4. **Namespace de pruebas: `pg-ha-lab`.** No tocar otros namespaces.
5. **No hardcodear StorageClass** salvo que sea imprescindible (y documentarlo).
6. **Todo lo que se documenta, se probó.** Nada de procedimientos sin ejecutar.
7. **Idempotencia:** los scripts deben poder correrse dos veces sin romper nada.
8. **Cuidado con las labels.** Los pods auxiliares (backup, failover) no deben
   llevar `app.kubernetes.io/name: postgresql` ni `instance: postgres`, o entran
   como endpoints de los Services de la BD.

## Convenciones

- Documentación y comentarios en **español**. Identificadores y logs en inglés.
- Prefijo de recursos: `postgres-`.
- Labels comunes: `app.kubernetes.io/{name,instance,part-of,component}`.
- `PGDATA` real: `/var/lib/pgsql/data/userdata`.
- Cambios de template requieren borrar pods a mano (`updateStrategy: OnDelete`).

## Flujo de trabajo

1. Leer `docs/` antes de proponer cambios.
2. Un commit por avance, mensaje claro.
3. Aplicar en el cluster y **verificar con evidencia**.
4. Correr `./tests/run-all.sh rapido` antes de cerrar un avance; `run-all.sh`
   completo antes de un release.
5. Actualizar la documentación en el mismo commit.
6. Pedir revisión a Codex (pane de tmux) en cada hito: corrección de YAML/scripts,
   riesgos de split-brain o pérdida de datos, idempotencia y coherencia con esto.

## Comandos

```bash
./scripts/deploy.sh                 # desplegar (overlay lab)
./scripts/verify-replication.sh     # verificar replicación
./scripts/failover-manual.sh        # promover una réplica
./scripts/backup-now.sh             # backup manual
./scripts/restore-backup.sh <dump>  # restore a una base nueva
./scripts/teardown.sh               # destruir
./tests/run-all.sh rapido           # pruebas no destructivas
```

## Prohibido

- Instalar operadores (OLM) para Postgres.
- Usar `docker.io/library/postgres` en manifiestos desplegables.
- Credenciales reales o StorageClass de otro cluster en el repo.
- Documentar algo que no se probó.
