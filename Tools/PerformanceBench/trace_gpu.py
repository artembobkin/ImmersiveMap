#!/usr/bin/env python3
# Copyright (c) 2025-2026 ImmersiveMap contributors.
# SPDX-License-Identifier: MIT
"""Per-second GPU load and on-screen frame rate from an xctrace export.

    xcrun xctrace export --input X.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' --output gpu.xml
    xcrun xctrace export --input X.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="displayed-surfaces-per-second"]' --output dsps.xml
    xcrun xctrace export --input X.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-application-encoders-list"]' --output enc.xml
    Tools/PerformanceBench/trace_gpu.py gpu.xml dsps.xml [enc.xml]

xctrace XML interns repeated values: an element with id="N" defines a value,
a later element with ref="N" repeats it, so both must be resolved.
"""
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict


def resolve(root):
    """Maps every id to its element so ref lookups can be resolved."""
    table = {}
    for el in root.iter():
        i = el.get("id")
        if i is not None:
            table[i] = el
    return table


def value(el, table):
    ref = el.get("ref")
    return table[ref] if ref is not None else el


def rows(path):
    root = ET.parse(path).getroot()
    table = resolve(root)
    schema = root.find(".//schema")
    cols = [c.find("mnemonic").text for c in schema.findall("col")]
    for row in root.iter("row"):
        cells = list(row)
        out = {}
        for name, cell in zip(cols, cells):
            cell = value(cell, table)
            out[name] = cell
        yield out


def text_number(el):
    t = el.text
    try:
        return int(t)
    except (TypeError, ValueError):
        return None


def main():
    gpu_path, dsps_path = sys.argv[1], sys.argv[2]
    encoder_labels = {}
    if len(sys.argv) > 3:
        # metal-application-encoders-list: encoder id to the label the app
        # gave it, which the GPU intervals carry only as an id.
        for r in rows(sys.argv[3]):
            enc = r.get("encoder-id")
            lab = r.get("encoder-label")
            if enc is not None and lab is not None:
                key = enc.text or enc.get("fmt")
                encoder_labels[key] = lab.get("fmt") or lab.text or ""
    per_second_busy = defaultdict(float)
    per_second_channels = defaultdict(lambda: defaultdict(float))
    per_second_buffers = defaultdict(set)
    buffer_span = {}
    by_label = defaultdict(float)
    for r in rows(gpu_path):
        start = text_number(r["start"])
        duration = text_number(r["duration"])
        if start is None or duration is None:
            continue
        process = r.get("process")
        process_name = (process.get("fmt") or process.text or "") if process is not None else ""
        if "PerformanceBench" not in process_name:
            continue
        depth = r.get("event-depth")
        depth_value = text_number(depth) if depth is not None else 0
        channel = r["channel-name"].get("fmt") or r["channel-name"].text or "?"
        second = start // 1_000_000_000
        frame = r.get("frame-number")
        cb_id = (frame.text or frame.get("fmt")) if frame is not None and (frame.text or frame.get("fmt")) else None
        # Depth-0 intervals are the per-encoder GPU work; sum them per channel.
        if depth_value == 0:
            enc_el = r.get("encoder-id")
            enc_key = (enc_el.text or enc_el.get("fmt")) if enc_el is not None else None
            label = encoder_labels.get(enc_key, "")
            by_label[(channel, label or "(unlabeled)")] += duration / 1e6
            per_second_channels[second][channel] += duration / 1e6
            per_second_busy[second] += duration / 1e6
            if cb_id:
                per_second_buffers[second].add(cb_id)
                lo, hi = buffer_span.get(cb_id, (start, start + duration))
                buffer_span[cb_id] = (min(lo, start), max(hi, start + duration))

    swaps = {}
    for r in rows(dsps_path):
        start = text_number(r["start"])
        count = text_number(r["count"])
        if start is not None and count is not None:
            swaps[start // 1_000_000_000] = count

    spans = sorted((hi - lo) / 1e6 for lo, hi in buffer_span.values())

    def pct(p):
        return spans[min(len(spans) - 1, int(len(spans) * p))] if spans else 0

    print("second  swaps/s  gpu ms/s  gpu frames  channels")
    for second in sorted(set(per_second_busy) | set(swaps)):
        channels = ", ".join(f"{k} {v:.0f}" for k, v in sorted(per_second_channels[second].items()))
        print(f"{second:6d}  {swaps.get(second, 0):7d}  {per_second_busy[second]:8.0f}  {len(per_second_buffers[second]):10d}  {channels}")
    print("\nGPU time by encoder label (ms over the whole trace):")
    for (channel, label), ms in sorted(by_label.items(), key=lambda kv: -kv[1])[:25]:
        print(f"  {ms:8.0f}  {channel:9} {label}")
    print(f"\nGPU frame span ms (first encoder start to last encoder end): p50 {pct(0.5):.1f}  p90 {pct(0.9):.1f}  p99 {pct(0.99):.1f}  max {spans[-1] if spans else 0:.1f}  (n={len(spans)})")


if __name__ == "__main__":
    main()
