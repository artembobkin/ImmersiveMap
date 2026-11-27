// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// What the extruded buildings tell the frame (`FrameStateBoard`), set in
/// `update` by `BuildingExtrusionRenderSubsystem`.
struct BuildingFrameState: FrameState {
    /// How far the extruded buildings have risen out of the ground this
    /// frame (`ExtrusionRise`), by the tile and the quarters they draw
    /// from: a label on a roof rises with the buildings drawn under it,
    /// whichever tile draws them.
    var rise: BuildingRiseCoverage = .none
    /// The building placements the frame draws: the coverage's
    /// (`TilePlacementState.buildingPlaceTilesContext`) with buildings,
    /// less the ones off the buildings' zoom or waiting for their model
    /// tile. What casts shadows this frame.
    var drawnPlacements: [PlaceTile] = []
    /// What changes while the buildings rise: the shadow map is drawn
    /// again while it does.
    var riseSignature: Float = 0
}
