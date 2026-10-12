// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TilePlacementState.swift
//  ImmersiveMap
//

import Foundation

struct TilePlacementState {
    nonisolated(unsafe) static let empty = TilePlacementState(placeTilesContext: .empty,
                                          buildingPlaceTilesContext: .empty,
                                          rasterPlacements: [],
                                          rasterGroundSlots: [],
                                          placementVersion: 0,
                                          visibleTilesCount: 0,
                                          readyTilesCount: 0,
                                          requestedTilesCount: 0,
                                          renderedTilesCount: 0)

    let placeTilesContext: PlaceTilesContext
    /// The tiles that may draw their buildings this frame: the near
    /// field's resident tiles of the target zoom, each in its own place,
    /// with no overlaps (`BuildingCoveragePlanner`). The building subsystem
    /// draws those at the buildings' zoom and not waiting for a model tile
    /// (`FrameContextSharedState.drawnBuildingPlacements`), by the depth
    /// test alone. Empty on the globe.
    let buildingPlaceTilesContext: PlaceTilesContext
    /// The raster tiles drawn this frame, each in its place
    /// (`RasterTileStore`, `RasterStandInPlanner`), finest first.
    let rasterPlacements: [RasterTilePlacement]
    /// The raster targets whose ground the textures draw whole, their own
    /// or their stand-ins': the vector placements in their slots draw no
    /// fills there. A raster target the textures leave uncovered is not
    /// among them, and its ground is the vector placements', as a vector
    /// target's.
    let rasterGroundSlots: Set<VisibleTile>
    let placementVersion: UInt64
    let visibleTilesCount: Int
    let readyTilesCount: Int
    let requestedTilesCount: Int
    let renderedTilesCount: Int
}
