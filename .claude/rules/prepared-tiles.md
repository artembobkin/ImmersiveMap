---
paths:
  - "Sources/ImmersiveMap/Tile/Parse/**"
  - "Sources/ImmersiveMap/Tile/Prepared/**"
  - "Sources/ImmersiveMap/Tile/Builders/**"
  - "Sources/ImmersiveMap/Tile/Loading/**"
  - "Sources/ImmersiveMap/Style/**"
  - "Sources/ImmersiveMap/Schema/**"
  - "Sources/ImmersiveMap/VectorTileAdaptation/**"
---

# Changes that need the tiles rebuilt

The engine parses a tile once and keeps the result on disk, the prepared cache (`~/Library/Caches/MapPreparedTiles/v<format>/<namespace>`). Its key is the tile source and the style's configuration fingerprint, not the code. A change to what the parser bakes into a tile (a stroke width, a colour, a cap or join, a pass added or removed, a field read differently) is therefore invisible in every app that keeps its caches, which is every app except `Develop/`: the app goes on serving tiles baked by the previous build, and the person at the screen reports "nothing changed".

Such a change bumps `PreparedTileDiskCaching.preparedFormatVersion` (`Tile/Loading/PreparedTileDiskCaching.swift`), with a numbered comment saying what changed and the test in `PreparedTileDiskCodecTests` that pins the number, so the build invalidates the old tiles itself. A warm machine is cleared by hand with `rm -rf ~/Library/Caches/MapPreparedTiles`.
