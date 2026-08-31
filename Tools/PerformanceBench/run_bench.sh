#!/bin/sh
# Copyright (c) 2025-2026 ImmersiveMap contributors.
# SPDX-License-Identifier: MIT
#
# Runs the benchmark matrix on a physical iPhone and collects one JSON per
# run into Tools/PerformanceBench/Output/ (gitignored).
#
#   Tools/PerformanceBench/run_bench.sh <device-id> [engine:cache ...]
#
# The engine name picks the app: immersivemap* runs ImmersiveMapBench and
# mapbox* runs MapboxBench, so both apps must already be built and installed
# for the default matrix (see README.md). Without an
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
  cache="${combo##*:}"
  # One app per SDK, so a run's memory belongs to its engine alone.
  case "$engine" in
    immersivemap*) BUNDLE_ID="com.artembobkin.ImmersiveMapBench" ;;
    mapbox*) BUNDLE_ID="com.artembobkin.MapboxBench" ;;
    *) echo "unknown engine $engine"; exit 1 ;;
  esac
  index=$((index + 1))
  stamp="$(date +%H%M%S)"
  log="$OUT/run-$index-$engine-$cache-$stamp.log"
  echo "== run $index: $engine / $cache -> $log"
  xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing \
    --environment-variables "{\"BENCH_ENGINE\":\"$engine\",\"BENCH_CACHE\":\"$cache\"}" \
    "$BUNDLE_ID" > "$log" 2>&1 || echo "   launch returned $? (see log)"
  awk '/BENCH_RESULT_BEGIN/{flag=1; next} /BENCH_RESULT_END/{flag=0} flag' "$log" \
    > "$OUT/run-$index-$engine-$cache-$stamp.json"
  if [ ! -s "$OUT/run-$index-$engine-$cache-$stamp.json" ]; then
    echo "   no result in the log"
  fi
  sleep "$COOLDOWN"
done
echo "== done"
