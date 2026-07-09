// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit


class MetalTile: Hashable {
    static func == (lhs: MetalTile, rhs: MetalTile) -> Bool {
        return lhs.tile.x == rhs.tile.x && lhs.tile.z == rhs.tile.z && lhs.tile.y == rhs.tile.y
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(tile.x)
        hasher.combine(tile.y)
        hasher.combine(tile.z)
    }
    
    let tile            : Tile
    let tileBuffers     : TileBuffers
    
    
    init(
        tile: Tile,
        tileBuffers: TileBuffers,
    ) {
        self.tile = tile
        self.tileBuffers = tileBuffers
    }
}
