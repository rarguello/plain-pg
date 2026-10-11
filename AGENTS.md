# AGENTS.md — Lineamientos del proyecto `pg-ha`

Este archivo define las reglas que **cualquier agente** (OpenCode, Codex, o humano)
debe seguir al trabajar en este repositorio. Léelo completo antes de tocar nada.

---

## 1. Qué es este proyecto

`pg-ha` demuestra **replicación streaming de PostgreSQL en OpenShift usando
únicamente objetos nativos de Kubernetes** (StatefulSet, Services, ConfigMaps,
Secrets, PVCs, CronJob). No usa operadores, no usa CRDs, no usa CloudNativePG /
Zalando / StackGres / Crunchy / Patroni / Stolon ni ningún controlador de terceros.

- **Objetivo principal:** 1 primary (pod ordinal 0) + 1 réplica hot standby (pod
  ordinal 1) que replica por WAL streaming.
- **Failover:** manual documentado; además hay un failover automático
  *best-effort* opcional (CronJob). El manual es el camino soportado.
- **Entorno objetivo:** OpenShift (probado en OCP 4.21, cluster SNO de
  laboratorio `sno.virt.daytwo.dev`). También funciona en Kubernetes vanilla.
- **Imagen:** PostgreSQL 18 sobre **UBI** (`registry.redhat.io/rhel10/postgresql-18`),
  fijada por digest. Si se cambia de imagen, actualizar el digest y el README.

## 2. Reglas duras (no negociables)

1. **Nada de operadores ni CRDs.** Solo objetos core de Kubernetes.
2. **Nada de secretos reales en git.** El Secret se genera con
   `scripts/generate-secret.sh` y vive fuera del repo (`.gitignore`). El archivo
   versionado es `manifests/01-secret.example.yaml` con valores de relleno.
3. **La imagen debe ser UBI.** Nada de `docker.io/library/postgres` en los
   manifiestos desplegables (se puede mencionar como alternativa en la doc).
4. **Namespace único de pruebas:** `pg-ha-lab`. No tocar otros namespaces.
5. **Storage:** usar la StorageClass por defecto del cluster (no hardcodear
   `storageClassName` salvo que sea imprescindible; si se hardcodea, documentarlo).
6. **Todo cambio se prueba en el cluster antes de darlo por bueno.** No se
   documenta nada que no se haya ejecutado.
7. **Idempotencia:** todo script (`deploy.sh`, etc.) debe poder correrse dos
   veces sin romper nada.

## 3. Convenciones

- **Idioma:** documentación y comentarios en **español**. Identificadores de
  código, nombres de recursos y mensajes de log en inglés.
- **Prefijo de recursos:** `postgres-` (StatefulSet `postgres`, Services
  `postgres-hl` / `postgres-rw` / `postgres-ro`).
- **Etiquetas comunes en todos los recursos:**
  ```yaml
  app.kubernetes.io/name: postgresql
  app.kubernetes.io/instance: postgres
  app.kubernetes.io/part-of: pg-ha
  app.kubernetes.io/component: database
  ```
- **PGDATA real** de la imagen sclorg: `/var/lib/pgsql/data/userdata`
  (definido por `set_pgdata` en `common.sh`, no por env `PGDATA`).
- **Rol del pod** se decide al arrancar leyendo el ConfigMap `postgres-role`
  (clave `primary_pod`). El pod cuyo nombre coincide es primary; el resto, réplica.
- **Scripts** viven en ConfigMaps montados en `/opt/app-root/src/...` para
  reutilizar los *hooks* de la imagen sclorg (`postgresql-start`, `postgresql-init`).

## 4. Cómo trabajar (flujo obligatorio)

1. Leer `docs/` y este archivo antes de proponer cambios.
2. Cambios pequeños y verificables. Un commit por avance lógico, mensaje claro.
3. Aplicar en el cluster y **verificar con evidencia** (salida de comandos,
   `pg_stat_replication`, `pg_is_in_recovery()`, logs). Guardar evidencia en
   `docs/` cuando sea un hito (ej. `docs/evidencia/`).
4. Antes de cerrar un avance: **hacer que Codex revise** el diff (ver §6).
5. Actualizar la documentación afectada en el mismo commit.

## 5. Comandos útiles

```bash
# Desplegar todo (idempotente)
./scripts/deploy.sh

# Ver estado
oc -n pg-ha-lab get pods,pvc,svc,cm
oc -n pg-ha-lab exec postgres-0 -- psql -U postgres -c 'SELECT * FROM pg_stat_replication;'

# Verificación de replicación completa
./scripts/verify-replication.sh

# Failover manual (runbook paso a paso)
./scripts/failover-manual.sh

# Destruir todo (borra PVCs)
./scripts/teardown.sh
```

## 6. Revisión con Codex

Hay una sesión de Codex corriendo en otra *pane* de tmux. Para pedir revisión,
enviar la instrucción a esa pane (ver skill `tmux-panes`). Pedir revisión:
- al terminar cada hito,
- antes de cada commit "grande",
- ante cualquier duda técnica seria.

La revisión debe cubrir: corrección de los YAML/scripts, riesgos de
split-brain/pérdida de datos, idempotencia, y coherencia con estos lineamientos.

## 7. Cosas prohibidas explícitamente

- Instalar operadores (OLM) para Postgres.
- Usar `docker.io/library/postgres` en manifiestos desplegables.
- Hardcodear credenciales reales o el storage class de otro cluster
  (`ocs-storagecluster-ceph-rbd`, etc.).
- "Arreglar" algo en el cluster sin reflejarlo en el repo.
- Documentar procedimientos no probados.

## 8. Estado actual / bitácora

Ver `docs/99-bitacora.md` para el historial de avances y decisiones.
