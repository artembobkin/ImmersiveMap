# Tile

`Tile` owns map tile identity, loading, parsing, styling, visibility, and
placement before prepared content reaches renderer-facing runtime state.

This folder is the main CPU pipeline for turning tile requests and vector tile
payloads into structured map content.

## Coordinate contract

Four y conventions exist around tile geometry, and every mirror bug this
engine has shipped was an unmarked handoff between the first two. The single
source of truth (constants, the named flip helpers, the full prose) is
`TileCoordinateSpace.swift` in this folder; the short form:

| Space | Axis | Who lives there |
|---|---|---|
| Tile space (raw MVT) | y grows SOUTH from the north edge, 0-4096 | The whole Parse layer: decoder output, road pre-pass/clipper/stitcher, label anchors, decoration builder inputs, debug grid stamps. This is what the tile bytes and the pipeline's GeoJSON speak. |
| Render space | y grows NORTH from the south edge (`4096 - y`) | Vertex storage and the GPU contract only: `ParsedPolygon`, `TileVertexIn`, extrusion meshes, `TileLocalClipMath` bounds. |
| Tile UV | v = y / 4096, same axis as tile space | Labels (divide, never flip), the tile point kernels, the debug overlays. |
| World | normalized mercator y grows south; the flat render world is y-up | `ImmersiveMapProjection` and the atlas planners. |

Rules: Parse works in tile space end to end. Render space is entered at
exactly ONE named point per geometry kind (`ParseLine`'s precompute for
lines, `ParsePolygon`'s tessellation for fills, `BuildingExtrusionCandidate`
construction for the extrusion path, the first line of each decoration
builder), always through `TileCoordinateSpace`, never as an inline
subtraction. Test fixtures near tile-geometry seams must be asymmetric in y:
a fixture symmetric about the tile centre mirrors onto itself and lets a
mirror bug pass, which is how two of the three shipped.

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
- Hard-coded bearer tokens, tile-provider API keys, private endpoints, or
  local secrets.

## Intended Flow

```text
Visible tile demand
  -> tile URL provider and loader
  -> tile parser and style resolver
  -> prepared tile content
  -> runtime state and renderer consumers
```
