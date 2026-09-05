#!/bin/sh
# Copyright (c) 2025-2026 ImmersiveMap contributors.
# SPDX-License-Identifier: MIT
#
# Runs the benchmark matrix on a physical iPhone and collects one JSON per
# run into Tools/PerformanceBench/Output/ (gitignored).
#
#   Tools/PerformanceBench/run_bench.sh <device-id> [engine:cache[:scenario] ...]
#
# The engine name picks the app: immersivemap* runs ImmersiveMapBench and
# mapbox* runs MapboxBench, so both apps must already be built and installed
# for the default matrix (see README.md). The scenario is `full` when
# omitted; `globe` replays the sphere-only script, `globe0` the
# fifteen-second zoom-0 spin, `globe16` the zoom 1-6 ladder, `flat9`
# the flat overview zooms. Without an
# explicit list the default matrix runs, interleaving the engines so thermal
# drift hits both alike. The device must be unlocked when a run starts.
set -eu

DEVICE="${1:?device id (xcrun xctrace list devices)}"
shift
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${BENCH_OUT:-$HERE/Output}"
mkdir -p "$OUT"
COOLDOWN="${BENCH_COOLDOWN:-25}"

if [ "$#" -eq 0 ]; then
  set -- immersivemap:cold mapbox-standard:cold immersivemap:warm mapbox-standard:warm \
         mapbox-streets:cold mapbox-streets:warm immersivemap:warm mapbox-standard:warm
fi

index=0
for combo in "$@"; do
  engine="${combo%%:*}"
  rest="${combo#*:}"
  cache="${rest%%:*}"
  scenario="${rest#*:}"
  if [ "$scenario" = "$cache" ]; then
    scenario="full"
  fi
  # One app per SDK, so a run's memory belongs to its engine alone.
  case "$engine" in
    immersivemap*) BUNDLE_ID="com.artembobkin.ImmersiveMapBench" ;;
    mapbox*) BUNDLE_ID="com.artembobkin.MapboxBench" ;;
    *) echo "unknown engine $engine"; exit 1 ;;
  esac
  index=$((index + 1))
  # BENCH_FPS, BENCH_EXIT, BENCH_CONTINUOUS and BENCH_ROOFS ride along from
  # this shell's environment when they are set.
  extra=""
  for var in BENCH_FPS BENCH_EXIT BENCH_CONTINUOUS BENCH_ROOFS; do
    eval "value=\${$var:-}"
    if [ -n "$value" ]; then
      extra="$extra,\"$var\":\"$value\""
    fi
  done
  stamp="$(date +%H%M%S)"
  name="run-$index-$engine-$cache-$scenario-$stamp"
  log="$OUT/$name.log"
  echo "== run $index: $engine / $cache / $scenario -> $log"
  xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing \
    --environment-variables "{\"BENCH_ENGINE\":\"$engine\",\"BENCH_CACHE\":\"$cache\",\"BENCH_SCENARIO\":\"$scenario\"$extra}" \
    "$BUNDLE_ID" > "$log" 2>&1 || echo "   launch returned $? (see log)"
  awk '/BENCH_RESULT_BEGIN/{flag=1; next} /BENCH_RESULT_END/{flag=0} flag' "$log" \
    > "$OUT/$name.json"
  if [ ! -s "$OUT/$name.json" ]; then
    echo "   no result in the log"
  fi
  sleep "$COOLDOWN"
done
echo "== done"
