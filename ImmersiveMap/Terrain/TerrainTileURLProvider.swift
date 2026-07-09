// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct TerrainTileURLProvider {
    let source: ImmersiveMapTerrainSource

    func url(for tile: Tile) -> URL {
        source.baseURL
            .appendingPathComponent(pathComponent(for: source.encoding))
            .appendingPathComponent(source.datum.rawValue)
            .appendingPathComponent("\(tile.z)")
            .appendingPathComponent("\(tile.x)")
            .appendingPathComponent("\(tile.y).png")
    }

    private func pathComponent(for encoding: ImmersiveMapTerrainSource.Encoding) -> String {
        switch encoding {
        case .mapboxTerrainRGB:
            return "mapbox"
        case .terrarium:
            return "terrarium"
        }
    }
}
