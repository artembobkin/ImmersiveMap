// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Tile instance visible in a specific wrapped world copy in flat mode.
struct VisibleTile: Hashable {
    let tile: Tile
    let loop: Int8

    init(tile: Tile, loop: Int8 = 0) {
        self.tile = tile
        self.loop = loop
    }

    init(x: Int, y: Int, z: Int, loop: Int8 = 0) {
        self.tile = Tile(x: x, y: y, z: z)
        self.loop = loop
    }

    var x: Int { tile.x }
    var y: Int { tile.y }
    var z: Int { tile.z }
}

enum TileLodKind: UInt8, Hashable {
    case exact = 0
    case coarseSubstitute = 1
    case retainedReplacement = 2
}
