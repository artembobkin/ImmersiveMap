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
/// How a placement draws: the switches of a ring rule (`FlatRingRule`),
/// lines, labels and the ground from a texture. A tile in its own slot
/// takes its slot's. A stand-in takes the rules of its own slot when the
/// frame has one for it, and the slot's it fills otherwise
/// (`TilePlacementPlanner`): a far ring's tile standing in for a near
/// slot its pan just opened keeps drawing as the far ring draws it, a
/// texture without lines or labels, so nothing on screen changes until
/// the slot's own tile lands, where the slot's rules put the far tile's
/// city labels and roads on the screen for the length of a disk read.
struct TileDrawRules: Hashable {
    var drawsLines = true
    var drawsLabels = true
    /// The ground from a texture of this size, nil for the geometry.
    var raster: RasterTileSpec?

    static let all = TileDrawRules()

    /// The finer of two rules, switch by switch: the geometry over a
    /// texture, the larger texture over the smaller, lines and labels on
    /// over off. For a stand-in carried from the last frame
    /// (`TilePlacementPlanner`): it draws no worse than it was shown and
    /// no worse than its new slot asks, and since every representation
    /// draws from the one resident tile, the finer costs nothing to load.
    func finer(than other: TileDrawRules) -> TileDrawRules {
        var finer = self
        finer.drawsLines = drawsLines || other.drawsLines
        finer.drawsLabels = drawsLabels || other.drawsLabels
        switch (raster, other.raster) {
        case (nil, _), (_, nil): finer.raster = nil
        case let (mine?, theirs?): finer.raster = mine.size >= theirs.size ? mine : theirs
        }
        return finer
    }
}

struct PlaceTile: Hashable {
    let metalTile: MetalTile
    let placeIn: VisibleTile
    let slot: VisibleTile
    let rules: TileDrawRules
    /// The flat map's horizon backdrop (`TileWorkingSetSubsystem
    /// .horizonBackdrops`): the pinned world tile drawn under every
    /// placement, flat on the plane, as a small texture without lines or
    /// labels, so the ground reaches the horizon whatever the rules place.
    /// It is no ground of the planner's: it takes no part in the ground's
    /// partition (`PlacementGroundSquare`), casts no shadow, asks for no
    /// terrain, and its mark lies under every other's.
    let isHorizonBackdrop: Bool

    init(metalTile: MetalTile,
         placeIn: VisibleTile,
         slot: VisibleTile? = nil,
         rules: TileDrawRules = .all,
         isHorizonBackdrop: Bool = false) {
        self.metalTile = metalTile
        self.placeIn = placeIn
        self.slot = slot ?? placeIn
        self.rules = rules
        self.isHorizonBackdrop = isHorizonBackdrop
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
