// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

extension ImmersiveMapTileSource {
    /// Tile source for a self-hosted OpenMapTiles-schema backend (the ImmersiveMap
    /// Tiles service). The loader appends `/{z}/{x}/{y}.mvt` to `tileBaseURL`; the
    /// optional key travels as `?key=` so a CDN can cache on the path.
    static func openMapTiles(tileBaseURL: URL, apiKey: String? = nil) -> ImmersiveMapTileSource {
        let source = ImmersiveMapTileSource(tileBaseURL: tileBaseURL)
        guard let apiKey, apiKey.isEmpty == false else {
            return source
        }
        return source.accessToken(apiKey, parameterName: "key")
    }
}
