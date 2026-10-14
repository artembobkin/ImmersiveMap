// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A tile drawn in a slot: the Metal tile, where it is drawn, and the
/// target it is drawn for. `placeIn` and the tile are the same when the
/// target has arrived, or when a resident descendant stands in at its own
/// extent. They differ when a resident ancestor is drawn in a finer
/// target's slot. `slot` is the target itself: the placement's own tile
/// when it has arrived, else the loading target the tile stands in for,
/// above a descendant or below an ancestor. The target's ring rule is the
/// placement's: whether it draws its lines and its fills, and the ring
/// whose terrain it rises by on the relief.
struct PlaceTile: Hashable {
    let metalTile: MetalTile
    let placeIn: VisibleTile
    let slot: VisibleTile

    init(metalTile: MetalTile, placeIn: VisibleTile, slot: VisibleTile? = nil) {
        self.metalTile = metalTile
        self.placeIn = placeIn
        self.slot = slot ?? placeIn
    }

    /// The tile is drawn in its own slot, at its own extent.
    var inOwnSlot: Bool { metalTile.tile == placeIn.tile }

    /// A placement is the tile where it is drawn: the slot is not part of
    /// its identity, so a stand-in found under two overlapping targets is
    /// placed once, for the first target found.
    static func == (lhs: PlaceTile, rhs: PlaceTile) -> Bool {
        lhs.metalTile == rhs.metalTile && lhs.placeIn == rhs.placeIn
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(metalTile)
        hasher.combine(placeIn)
    }
}
