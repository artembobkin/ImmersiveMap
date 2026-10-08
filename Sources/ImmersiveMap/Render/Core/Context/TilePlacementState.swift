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
    let placementVersion: UInt64
    let visibleTilesCount: Int
    let readyTilesCount: Int
    let requestedTilesCount: Int
    let renderedTilesCount: Int
}
