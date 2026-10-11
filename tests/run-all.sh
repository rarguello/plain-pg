#!/usr/bin/env bash
#
# run-all.sh -- corre la bateria de pruebas.
#
# Uso:
#   ./tests/run-all.sh              # todas (incluye destructivas: failover, teardown)
#   ./tests/run-all.sh rapido       # solo las no destructivas (t01-t06, t09, t10)
#   ./tests/run-all.sh t03 t04      # pruebas puntuales
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

ALL=(t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12 t13 t14 t15 t16 t17 t18 t19 t20 t21)
RAPIDO=(t01 t02 t03 t04 t05 t06 t09 t10 t12 t14 t18 t19 t21)

if [ "$#" -eq 0 ]; then
  SEL=("${ALL[@]}")
elif [ "$1" = "rapido" ]; then
  SEL=("${RAPIDO[@]}")
else
  SEL=("$@")
fi

RESULT=()
START="$(date +%s)"

for t in "${SEL[@]}"; do
  f="$(ls "$ROOT_DIR"/tests/"$t"_*.sh 2>/dev/null | head -1)"
  if [ -z "$f" ]; then
    echo "== $t: no encontrado"
    RESULT+=("SKIP $t")
    continue
  fi
  echo
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo "== $(basename "$f")"
  echo "═══════════════════════════════════════════════════════════════════════════"
  if bash "$f"; then
    RESULT+=("PASS $t")
  else
    RESULT+=("FAIL $t")
  fi
done

END="$(date +%s)"
echo
echo "═══════════════════════════════════════════════════════════════════════════"
echo "== RESUMEN  ($((END - START))s)"
echo "═══════════════════════════════════════════════════════════════════════════"
for r in "${RESULT[@]}"; do printf '  %s\n' "$r"; done

if printf '%s\n' "${RESULT[@]}" | grep -q '^FAIL'; then
  echo
  echo "  RESULTADO: HAY FALLOS"
  exit 1
fi
echo
echo "  RESULTADO: TODO OK"
