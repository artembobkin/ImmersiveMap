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

    init(tilePlacements: [TileAtlasPlaceTile]) {
        self.tilePlacements = tilePlacements
    }

    nonisolated(unsafe) static let empty = TileAtlasPlaceTilesContext(tilePlacements: [])
}
