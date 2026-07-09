// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

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
