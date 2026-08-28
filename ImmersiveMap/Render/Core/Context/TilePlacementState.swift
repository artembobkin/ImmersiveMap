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
                                          shadowCasterPlaceTilesContext: .empty,
                                          globeSurfaceSlots: [],
                                          placementVersion: 0,
                                          visibleTilesCount: 0,
                                          readyTilesCount: 0,
                                          requestedTilesCount: 0,
                                          renderedTilesCount: 0)

    let placeTilesContext: PlaceTilesContext
    /// Placements of the flat-mode horizon backdrop: drawn under the main
    /// coverage and excluded from labels/projections. Empty on the globe.
    let backdropPlaceTilesContext: PlaceTilesContext
    /// Placements of the off-screen sun-ward caster strip: rendered into the
    /// shadow cascade maps only, on top of the visible placements. Empty on
    /// the globe and with shadows disabled.
    let shadowCasterPlaceTilesContext: PlaceTilesContext
    /// Every target slot of the globe surface this frame (the preprocessed
    /// visible tiles): the placeholder grid draws each one, which is what
    /// writes the surface depth and paints the base under the tile geometry
    /// drawn on the sphere. Independent of which tiles have arrived.
    let globeSurfaceSlots: [Tile]
    let placementVersion: UInt64
    let visibleTilesCount: Int
    let readyTilesCount: Int
    let requestedTilesCount: Int
    let renderedTilesCount: Int
}
