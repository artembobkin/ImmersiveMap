---
paths:
  - "Sources/Mvt/**"
  - "Sources/MvtTestSupport/**"
  - "Tests/MvtTests/**"
---

# The Mapbox Vector Tile decoder

- The schema is read by hand in `Sources/Mvt/MvtTileDecoder.swift`, with field numbers and wire types spelled out per message. There is no generated code and no `.proto` file in the tree, and none is added.
- Tests build tile bytes with the test-side encoder in `Sources/MvtTestSupport/MvtTileEncoder.swift` (`MvtTileMessage`, `MvtLayerMessage`, `MvtFeatureMessage`), which is deliberately independent of the decoder so a round trip checks both against the specification, not against each other.
- The `Mvt` target knows nothing of the tile schema's meaning: no layer name, no style. That belongs to the engine.
