// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension ImmersiveMapTileSource {
    /// Tile source for a self-hosted OpenMapTiles-schema backend (the ImmersiveMap
    /// Tiles service). The loader appends `/{z}/{x}/{y}.mvt` to `tileBaseURL`.
    /// Credentials, when the endpoint needs them, travel as custom request
    /// headers or in a URL template's query string.
    static func immersiveMapTiles(tileBaseURL: URL) -> ImmersiveMapTileSource {
        // TileJSON sits next to the tile path: ".../tiles" -> ".../tiles.json".
        let tileJSONURL = tileBaseURL.deletingLastPathComponent().appendingPathComponent("tiles.json")
        return ImmersiveMapTileSource(tileBaseURL: tileBaseURL, tileJSONURL: tileJSONURL)
    }
}
