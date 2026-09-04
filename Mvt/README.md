# Mvt

`Mvt` is the Mapbox Vector Tile decoder: the hand-written reader of the
`vector_tile.proto` wire format (version 2.1) and the types it produces. It is
its own SwiftPM target so that the format code depends on nothing in the
engine and the engine consumes it through `import Mvt`. Every declaration is
`package` access, not `public`: every target of this package can use it, and
an app that links the `ImmersiveMap` product cannot see it at all.

## API

- `MvtTileDecoder.decode(data:)` walks the payload once and returns an
  `MvtDecodedTile`: the layers with their key and value tables, and each
  feature's `tags` and `geometry` left as byte ranges into the payload
  (`MvtPackedField`) rather than materialized arrays.
- `MvtGeometryDecoder` turns a feature's geometry field into `MultiPolygon`,
  `MultiLineString` or `MultiPoint`, straight from the packed bytes.
- `MvtAttributeDecoder` turns a feature's tags into `[String: MvtValue]`
  through the layer's tables. It lives here rather than in the parser so the
  per-integer loop and the varint reader specialize inside one module.
- `MvtValue` and `MvtGeometryType` are the schema's value and geometry kinds;
  `Point`, `Polygon` and the multi aliases are the tile-space geometry the
  decoder produces and the parser consumes in place.

What the module does not know: layer names, the tile schema's meaning, any
style. The engine's `MvtRoadLayerFold` (which merges the `streetscape` layer
into the road layer) is schema knowledge and stays in
`ImmersiveMap/Tile/Parse`.

## Files

- `MvtTileDecoder.swift`: the wire decoder, field numbers and wire types
  spelled out per message; there is no generated code and no `.proto` file.
- `MvtDecodedTile.swift`: the decoded model, `MvtPackedField`, and the two
  uint32 readers (a varint reader over a byte range, an array reader for the
  unpacked fallback) behind the internal `MvtUInt32Reading` protocol.
- `MvtGeometryDecoder.swift`: the geometry types and the command-stream
  decoder (MoveTo/LineTo/ClosePath with zigzag deltas).
- `MvtAttributeDecoder.swift`: the tag-pair loop.
- `MvtValue.swift`: `MvtValue` and `MvtGeometryType`.
- `TestSupport/`: the `MvtTestSupport` target, a regular target that is not a
  product: the test-side encoder (`MvtTileMessage`, `MvtLayerMessage`,
  `MvtFeatureMessage`, `MvtWireWriter`), deliberately independent of the
  decoder so a round trip checks both against the specification; the
  synthetic fixture tiles (`MvtFixtureTileMessages`); and the deterministic
  generator they draw from. Both test targets of the package depend on it.
- `Tests/`: the `MvtTests` target, kept here next to the code it covers and
  importing the module the way a client would, without `@testable`.
  `Package.swift` excludes `Tests` and `TestSupport` from the `Mvt` target's
  sources.
