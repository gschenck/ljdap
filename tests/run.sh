#!/bin/sh
# ljdap – Test-Runner. Führt alle tests/unit/*_test.lua unter jedem
# verfügbaren Interpreter aus (luajit, lua5.1). Rückgabe ≠ 0 bei Fehler.
# Aufruf: tests/run.sh [interpreter …]
set -u
cd "$(dirname "$0")/.." || exit 2

interps="${*:-luajit lua5.1}"
fail=0
ran=0
for lua in $interps; do
  if ! command -v "$lua" >/dev/null 2>&1; then
    echo "-- $lua nicht gefunden, übersprungen"
    continue
  fi
  for t in tests/unit/*_test.lua; do
    [ -e "$t" ] || continue
    ran=$((ran + 1))
    if "$lua" "$t"; then
      echo "ok   $lua $t"
    else
      echo "FAIL $lua $t"
      fail=$((fail + 1))
    fi
  done
done
echo "-- $ran Läufe, $fail Fehler"
[ "$ran" -gt 0 ] || { echo "-- keine Tests gelaufen"; exit 1; }
[ "$fail" -eq 0 ]
