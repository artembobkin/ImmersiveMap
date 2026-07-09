// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct GlobeTexturePlaceTile: Hashable {
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

struct GlobeTexturePlaceTilesContext {
    let tilePlacements: [GlobeTexturePlaceTile]

    init(tilePlacements: [GlobeTexturePlaceTile]) {
        self.tilePlacements = tilePlacements
    }

    static let empty = GlobeTexturePlaceTilesContext(tilePlacements: [])
}
