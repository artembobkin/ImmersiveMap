# Tile

`Tile` owns map tile identity, loading, parsing, styling, visibility, and
placement before prepared content reaches renderer-facing runtime state.

This folder is the main CPU pipeline for turning tile requests and vector tile
payloads into structured map content.

## Responsibilities

- Represent tiles and visible tile state.
- Build tile download URLs through provider-neutral interfaces.
- Download, retry, cache, and decode tile payloads.
- Parse vector tile geometry into prepared map content.
- Apply feature styles and organize geometry phases.
- Resolve flat and globe visible tile sets and placement retention.

## May Contain

- Tile identity, LOD, visibility, and placement models.
- Tile loading pipeline, downloader, retry, FIFO, and disk cache code.
- MVT parsing, clipping, decoding, bridge/roof/road geometry builders.
- Feature style models and default styling logic.
- Prepared tile serialization codecs and cache identity types.

## Must Not Contain

- Metal render graph, render passes, shader files, or GPU resource ownership.
- UIKit/AppKit/SwiftUI views, gesture recognizers, host-app controllers, or
  display link lifecycle code.
- Provider-specific label decision policy that belongs in
  `VectorTileAdaptation`.
- Runtime label cache/fade state that belongs in `Labels`.
- Hard-coded bearer tokens, Mapbox tokens, private endpoints, or local secrets.

## Intended Flow

```text
Visible tile demand
  -> tile URL provider and loader
  -> tile parser and style resolver
  -> prepared tile content
  -> runtime state and renderer consumers
```
