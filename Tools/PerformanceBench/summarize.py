#!/usr/bin/env python3
# Copyright (c) 2025-2026 ImmersiveMap contributors.
# SPDX-License-Identifier: MIT
"""Turns a folder of bench JSON results into Markdown comparison tables.

    Tools/PerformanceBench/summarize.py [Tools/PerformanceBench/Output]

Runs of the same engine, cache state and scenario are averaged; the run count
is shown. Runs written before scenarios existed count as the full scenario.
"""
import glob
import json
import os
import sys
from collections import defaultdict

WINDOWS = ["warmup", "tour", "pan", "idle"]
COLUMNS = [
    ("hostTicksPerSecond", "main-thread ticks/s", "{:.0f}"),
    ("hostIntervalP95Ms", "tick p95 ms", "{:.1f}"),
    ("hostIntervalMaxMs", "tick max ms", "{:.0f}"),
    ("hostHitches", "hitches", "{:.0f}"),
    ("hostHitchTimeMs", "hitch time ms", "{:.0f}"),
    ("engineFramesPerSecond", "engine frames/s", "{:.0f}"),
    ("cpuAveragePercent", "CPU avg %", "{:.0f}"),
    ("cpuPeakPercent", "CPU peak %", "{:.0f}"),
    ("mainThreadBusyAveragePercent", "main busy %", "{:.0f}"),
    ("memoryAverageMB", "mem avg MB", "{:.0f}"),
    ("memoryPeakMB", "mem peak MB", "{:.0f}"),
]


def load(folder):
    runs = []
    for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if "windows" in data:
            data["_file"] = os.path.basename(path)
            runs.append(data)
    return runs


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "Output")
    runs = load(folder)
    if not runs:
        print("no results in", folder)
        return
    first = runs[0]
    print(f"Device {first['device']}, iOS {first['systemVersion']}, view {first['viewSizePoints']} pt @{first['screenScale']}x, "
          f"target {first['targetFramesPerSecond']} Hz\n")
    print("| run | engine | cache | scenario | version | low power | thermal start -> end | baseline MB |")
    print("|---|---|---|---|---|---|---|---|")
    for r in runs:
        print(f"| {r['_file']} | {r['engine']} | {r['cacheState']} | {r.get('scenario', 'full')} | {r['engineVersion']} | "
              f"{r.get('lowPowerMode')} | "
              f"{r.get('thermalStateAtStart')} -> {r.get('thermalStateAtEnd')} | {r['memoryBaselineMB']:.0f} |")
    print()

    groups = defaultdict(list)
    for r in runs:
        groups[(r["engine"], r["cacheState"], r.get("scenario", "full"))].append(r)

    for window in WINDOWS:
        print(f"### {window}\n")
        print("| engine | cache | scenario | runs | " + " | ".join(c[1] for c in COLUMNS) + " |")
        print("|---|---|---|---|" + "|".join("---:" for _ in COLUMNS) + "|")
        for (engine, cache, scenario), rs in sorted(groups.items()):
            values = []
            for key, _, fmt in COLUMNS:
                samples = []
                for r in rs:
                    w = next((w for w in r["windows"] if w["name"] == window), None)
                    if w is not None and key in w:
                        samples.append(w[key])
                values.append(fmt.format(sum(samples) / len(samples)) if samples else "-")
            print(f"| {engine} | {cache} | {scenario} | {len(rs)} | " + " | ".join(values) + " |")
        print()


if __name__ == "__main__":
    main()
