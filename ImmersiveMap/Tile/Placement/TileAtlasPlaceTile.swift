// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct TileAtlasPlaceTile: Hashable {
    let placeTile: PlaceTile

    var metalTile: MetalTile {
        placeTile.metalTile
    }

    var placeIn: VisibleTile {
        placeTile.placeIn
    }

    var lodKind: TileLodKind {
        placeTile.lodKind
    }
}

struct TileAtlasPlaceTilesContext {
    let tilePlacements: [TileAtlasPlaceTile]
    /// Sub-slots of the frame's targets that no placement paints: the renderer
    /// fills them with blank map-colored tiles so a loading or holed coverage
    /// still reads as a solid surface and writes depth.
    let uncoveredSlots: [Tile]

    init(tilePlacements: [TileAtlasPlaceTile],
         uncoveredSlots: [Tile]) {
        self.tilePlacements = tilePlacements
        self.uncoveredSlots = uncoveredSlots
    }

    nonisolated(unsafe) static let empty = TileAtlasPlaceTilesContext(tilePlacements: [],
                                                                      uncoveredSlots: [])
}
