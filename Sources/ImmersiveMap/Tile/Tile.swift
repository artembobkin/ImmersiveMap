// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The `Tile` folder: tile identity, loading, parsing, styling, visibility and
/// placement, the CPU pipeline from a tile request to the prepared content the
/// renderer consumes. No Metal, render passes or GPU resources, no views,
/// gestures or display link, no schema-specific label policy (that is
/// `VectorTileAdaptation`), no runtime label state (`Labels`), and no keys,
/// tokens or private endpoints. Every geometry here follows the y-axis
/// contract stated once in `TileCoordinateSpace`.
///
/// Content identity of a vector tile.
struct Tile: Hashable {
    let x: Int
    let y: Int
    let z: Int

    // Check whether the current tile covers another tile.
    func covers(_ other: Tile) -> Bool {
        // A tile covers another if it has a lower zoom level
        // and contains the other tile's coordinates.
        if z >= other.z {
            return false
        }

        let scale = 1 << (other.z - z)
        let minX = x * scale
        let maxX = (x + 1) * scale - 1
        let minY = y * scale
        let maxY = (y + 1) * scale - 1

        return other.x >= minX && other.x <= maxX &&
               other.y >= minY && other.y <= maxY
    }

    func findParentTile(atZoom targetZoom: Int) -> Tile? {
        guard z >= targetZoom, targetZoom >= 0 else {
            return nil
        }

        let zoomDifference = z - targetZoom
        let parentX = x >> zoomDifference
        let parentY = y >> zoomDifference

        return Tile(x: parentX, y: parentY, z: targetZoom)
    }
}
