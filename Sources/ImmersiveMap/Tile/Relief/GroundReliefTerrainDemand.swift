// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The terrain store as the tile planner sees it
/// (`TileWorkingSetSubsystem`): which terrain tile a placement rises by,
/// whether it is in, the frame's demand, and the memory it lets go.
/// The planner hands over what it planned and the relief works out which
/// terrain that needs (`GroundReliefDemand`): nothing of the rings'
/// terrain zooms, the relief's zooms or its collapse reaches the planner.
/// Nothing of how the terrain is drawn either, which the planner reads off
/// the frame's `GroundReliefFrame`, and nothing a frame sets.
protocol GroundReliefTerrainDemand: AnyObject {
    /// Grows with every change to the terrain in: the placements are
    /// planned again when it moves.
    var version: UInt64 { get }
    /// Whether a wanted terrain tile is still to come.
    var hasLoadsPending: Bool { get }
    /// The terrain tile a source drawn in a ring of `targetZoom` shades its
    /// slopes by (`PlaceTile.terrain`).
    func terrainSource(for tile: Tile, targetZoom: Int) -> Tile
    /// The terrain tile a source drawn in a ring of `targetZoom` displaces
    /// its grid by (`PlaceTile.displacement`).
    func displacementSource(for tile: Tile, targetZoom: Int) -> Tile
    /// Whether a terrain tile is in, or counts as in because it cannot
    /// come.
    func isResident(_ tile: Tile) -> Bool
    /// The frame's terrain demand, once a frame: what the relief loads and
    /// keeps, worked out from the frame's targets, the placements shown,
    /// the terrain the planner found missing and the point the camera
    /// looks at (`GroundReliefStore.request(for:...)`).
    func request(for relief: GroundReliefFrame,
                 onFlatMap: Bool,
                 tileZoom: Int,
                 targets: [VisibleTile],
                 shown: [PlaceTile],
                 missing: [Tile],
                 centerWorldMercator: SIMD2<Double>)
    /// Releases every terrain tile, for a memory warning.
    func removeAll()
}
