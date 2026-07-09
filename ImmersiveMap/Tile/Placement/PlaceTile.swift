// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct PlaceTile: Hashable {
    let metalTile: MetalTile
    let placeIn: VisibleTile
    let lodKind: TileLodKind

    func isReplacement() -> Bool {
        return lodKind != .exact || metalTile.tile != placeIn.tile
    }
}
