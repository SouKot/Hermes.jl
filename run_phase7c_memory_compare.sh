#!/usr/bin/env bash
set -euo pipefail

ROOT="/run/media/sourabh/SANDISK-2TB/antigravity/ABM"
GODOT_DIR="$ROOT/godot"
SCALE="${SIMVIZ_COMPARE_SCALE:-500000}"

/usr/bin/time -v env SIMVIZ_BENCH_SCALES="$SCALE" SIMVIZ_FORCE_GENERIC=1 godot --headless --path "$GODOT_DIR" \
  --script res://tests/performance_resilience_smoke.gd 2>&1 | tee /tmp/simviz_generic_memory.log
/usr/bin/time -v env SIMVIZ_LARGE_SCALES="$SCALE" godot --headless --path "$GODOT_DIR" \
  --script res://tests/large_scale_memory_benchmark.gd 2>&1 | tee /tmp/simviz_packed_memory.log

generic_rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' /tmp/simviz_generic_memory.log | tail -n 1)
packed_rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' /tmp/simviz_packed_memory.log | tail -n 1)
if [[ -z "$generic_rss" || -z "$packed_rss" ]]; then
  echo "Unable to read one or both RSS measurements" >&2
  exit 1
fi
printf 'comparison_scale=%s generic_peak_rss_kb=%s packed_peak_rss_kb=%s reduction_ratio=%.3f\n' \
  "$SCALE" "$generic_rss" "$packed_rss" "$(awk -v g="$generic_rss" -v p="$packed_rss" 'BEGIN { print g / p }')"
