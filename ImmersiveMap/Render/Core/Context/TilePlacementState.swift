// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TilePlacementState.swift
//  ImmersiveMap
//

import Foundation

struct TilePlacementState {
    nonisolated(unsafe) static let empty = TilePlacementState(placeTilesContext: .empty,
                                          backdropPlaceTilesContext: .empty,
                                          buildingPlaceTilesContext: .empty,
                                          placementVersion: 0,
                                          visibleTilesCount: 0,
                                          readyTilesCount: 0,
                                          requestedTilesCount: 0,
                                          renderedTilesCount: 0)

    let placeTilesContext: PlaceTilesContext
    /// Placements of the flat-mode horizon backdrop: drawn under the main
    /// coverage and excluded from labels/projections. Empty on the globe.
    let backdropPlaceTilesContext: PlaceTilesContext
    /// The tiles that draw their buildings this frame, a partition of the
    /// near field with no overlaps (`BuildingCoveragePlanner`): what the
    /// building and shadow passes draw, by the depth test alone. Empty on
    /// the globe.
    let buildingPlaceTilesContext: PlaceTilesContext
    let placementVersion: UInt64
    let visibleTilesCount: Int
    let readyTilesCount: Int
    let requestedTilesCount: Int
    let renderedTilesCount: Int
}
