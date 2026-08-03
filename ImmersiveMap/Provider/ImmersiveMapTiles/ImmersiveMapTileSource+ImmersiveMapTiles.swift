// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension ImmersiveMapTileSource {
    /// Tile source for a self-hosted OpenMapTiles-schema backend (the ImmersiveMap
    /// Tiles service). The loader appends `/{z}/{x}/{y}.mvt` to `tileBaseURL`.
    ///
    /// The optional key travels in an `Authorization: Bearer` header rather than
    /// a query parameter. A key in the URL would put it in the CDN cache key, so
    /// every customer would get their own copy of tiles that are byte-identical
    /// for everyone — worse hit rate for the same bytes.
    static func immersiveMapTiles(tileBaseURL: URL, apiKey: String? = nil) -> ImmersiveMapTileSource {
        // TileJSON sits next to the tile path: ".../tiles" -> ".../tiles.json".
        let tileJSONURL = tileBaseURL.deletingLastPathComponent().appendingPathComponent("tiles.json")
        let source = ImmersiveMapTileSource(tileBaseURL: tileBaseURL, tileJSONURL: tileJSONURL)
        guard let apiKey, apiKey.isEmpty == false else {
            return source
        }
        return source.token(apiKey)
    }
}
