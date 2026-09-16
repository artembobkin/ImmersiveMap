// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A tile in a specific copy of the world. The flat map repeats the world
/// along the x axis so the antimeridian is never an edge, and `worldWrap`
/// says which copy this is: 0 the world itself, -1 the copy to its west,
/// 1 the copy to its east. The same `Tile` in two copies is two places on
/// screen, a world's width apart.
struct VisibleTile: Hashable {
    let tile: Tile
    let worldWrap: Int8

    init(tile: Tile, worldWrap: Int8 = 0) {
        self.tile = tile
        self.worldWrap = worldWrap
    }

    init(x: Int, y: Int, z: Int, worldWrap: Int8 = 0) {
        self.tile = Tile(x: x, y: y, z: z)
        self.worldWrap = worldWrap
    }

    var x: Int { tile.x }
    var y: Int { tile.y }
    var z: Int { tile.z }
}

enum TileLodKind: UInt8, Hashable {
    case exact = 0
    case coarseSubstitute = 1
    /// A resident descendant standing in for a target that has not
    /// arrived, drawn at its own extent.
    case retainedReplacement = 2
}
