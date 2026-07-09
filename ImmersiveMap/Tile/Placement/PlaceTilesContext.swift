// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct PlaceTilesContext {
    /// Logical tile layout for flat/extruded geometry rendering:
    /// carries GPU tile payload and placement target tile.
    let tilePlacements: [PlaceTile]
    
    init(tilePlacements: [PlaceTile]) {
        self.tilePlacements = tilePlacements
    }

    static let empty = PlaceTilesContext(tilePlacements: [])
}
