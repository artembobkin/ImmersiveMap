# Parse

`Parse` turns the bytes of one vector tile into a `ParsedTile`: every
geometry layer tessellated and packed into GPU-ready streams, the styles
they index, and the labels the layers carried. It is a module with one
input contract and one output contract, and nothing inside it reaches past
either.

## Boundary

What a parse depends on comes in through `TileMvtParser`'s initializer and
nothing else:

- `TileParseOptions`: the settings a parse reads, picked out of
  `ImmersiveMapSettings` by the caller (`TileParseOptions(settings:)` is the
  one place this folder looks at the settings tree). Every field is part of
  the prepared-tile identity.
- `TileLabelDecisions`: the label policy (which text, which icon, which
  priority, which spelling the language and the atlas allow), assembled in
  `VectorTileAdaptation`. The parser asks, it answers.
- `DetermineFeatureStyle`: the map style, which turns a feature's layer
  and attributes into a `FeatureStyle`.

What a parse produces is the `Contract/` folder: `ParsedTile` and the
types it is made of (`DrawingPolygonBytes`, `DrawingExtrudedBytes`,
`DrawingGeometryLayer`, `ExtrudedVertexIn`, `ParsedTextLabel`,
`ParsedRoadTextLabel`), plus the types the styles and the render side
share with the parser (`ParsedPolygon`, `ParseGeometryStyleData`,
`RoadStructureKind`, `RoadDecorationKind`). `Render`, `Style` and the
`Provider` files name these types directly and never the parser's
internals.

## Shape

`TileMvtParser` is the dispatcher. `readingStage` walks the layers; per
layer it decodes the attributes and resolves the style of every feature
exactly once, builds the layer's road context, and hands each feature to
the reader for its geometry kind. `TileUnificationStage` then packs the
result into the streams. The readers, one per geometry kind, each a
struct with no state across tiles:

- `Ground/GroundFeatureReader`: polygon fills, the ocean split, and what
  every tile gets under and around its features (background, debug frame,
  the sphere subdivision).
- `Buildings/BuildingFeatureReader`: what a footprint extrudes to, with
  the resolver that tells outlines from parts once the tile is read and
  the mesh builder that raises the walls and the roof (`Roof/`).
- `Roads/LineFeatureReader`: a line feature's ribbons, decorations and
  road label, on the separate-road path or as plain ground geometry;
  `RoadSurfaceAreaReader` the carriageway surfaces; `RoadLayerPrecomputation`
  the per-layer pre-pass (clipping by the surfaces, stitching, junctions)
  the two read from.
- `Labels/LabelFeatureReader`: point labels, and the synthesized ocean
  and sea names of the coarse zooms.

Every reader appends into one `ReadingStageResult` through its methods,
which is where the invariants between the buckets live. The per-tile
tessellators and clipper (`TileParseTools`) are made per parse: the parser
is shared between the loading threads and `ParsePolygon` keeps scratch
buffers.

## Responsibilities

- Decode a tile's layers, attributes and geometry (`TileLayerGeometry`,
  the `Mvt` target underneath).
- Clip, tessellate and pack geometry into the tile's streams.
- Read tile attributes the way a loose schema needs (`MvtValue+Attributes`).
- Decide, per feature, which reader a geometry goes to and with which
  style.

## Must Not Contain

- `ImmersiveMapSettings` outside `TileParseOptions(settings:)`.
- Label policy: which name field, which language chain, which priority.
  That is `VectorTileAdaptation`, reached through `TileLabelDecisions`.
- Metal, GPU resources, or anything of `Render`.
- Tile loading, caching or networking.

## Coordinate contract

The whole folder works in tile space (y grows south from the north edge,
0-4096) and enters render space at exactly one named point per geometry
kind, always through `TileCoordinateSpace`. The full contract is in
`Tile/README.md` and `TileCoordinateSpace.swift`.

## Intended Flow

```text
Tile bytes
  -> MvtTileDecoder, MvtRoadLayerFold
  -> TileMvtParser.readingStage: attributes and style once per feature,
     RoadLayerContext per layer, one reader per feature
  -> ReadingStageResult
  -> TileUnificationStage
  -> ParsedTile
```
