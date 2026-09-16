// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A tile drawn in a slot: the Metal tile, and the target it is drawn
/// for. The two are the same tile when the target has arrived, or when a
/// resident descendant stands in at its own extent. They differ when a
/// resident ancestor is drawn in a finer target's slot.
struct PlaceTile: Hashable {
    let metalTile: MetalTile
    let placeIn: VisibleTile

    /// The tile is drawn in its own slot, at its own extent.
    var inOwnSlot: Bool { metalTile.tile == placeIn.tile }
}
