# Evidencia de pruebas

Corridas de la batería (`tests/run-all.sh`) contra el cluster de laboratorio
(OpenShift 4.21, SNO `sno.virt.daytwo.dev`).

Cada archivo es la salida completa de una corrida. Al final de cada uno está el
resumen por test y el resultado global.

| Archivo | Fecha | Resultado |
|---|---|---|
| `2026-10-11-suite-completa.txt` | 2026-10-11 | ver el archivo |

Cómo reproducir:

```bash
./tests/run-all.sh            # todas (incluye destructivas)
./tests/run-all.sh rapido     # solo las no destructivas
```
