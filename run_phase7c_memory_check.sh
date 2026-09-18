#!/usr/bin/env bash
set -euo pipefail

ROOT="/run/media/sourabh/SANDISK-2TB/antigravity/ABM"
GODOT_DIR="$ROOT/godot"
ITERATIONS="${SIMVIZ_MEMORY_ITERATIONS:-20}"

for ((iteration = 1; iteration <= ITERATIONS; iteration++)); do
  SIMVIZ_BENCH_SCALES="${SIMVIZ_MEMORY_SCALE:-10000}" /usr/bin/time -v godot --headless --path "$GODOT_DIR" --script res://tests/performance_resilience_smoke.gd \
    2>&1 | tee "/tmp/simviz_memory_check_${iteration}.log"
done

cat /tmp/simviz_memory_check_*.log > /tmp/simviz_memory_check.log

peak_kb=$(awk -F': ' '/Maximum resident set size/ {print $2}' /tmp/simviz_memory_check.log | tail -n 1)
if [[ -z "$peak_kb" ]]; then
  echo "Unable to read peak resident memory" >&2
  exit 1
fi
printf 'peak_rss_kb=%s iterations=%s\n' "$peak_kb" "$ITERATIONS"
