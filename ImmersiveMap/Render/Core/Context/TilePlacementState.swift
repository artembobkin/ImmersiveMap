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
                                          tileAtlasPlaceTilesContext: .empty,
                                          placementVersion: 0,
                                          visibleTilesCount: 0,
                                          readyTilesCount: 0,
                                          requestedTilesCount: 0,
                                          renderedTilesCount: 0)

    let placeTilesContext: PlaceTilesContext
    /// Размещения подложки горизонта плоского режима: рисуются под основным
    /// покрытием и не участвуют в лейблах/проекциях. На глобусе пусто.
    let backdropPlaceTilesContext: PlaceTilesContext
    let tileAtlasPlaceTilesContext: TileAtlasPlaceTilesContext
    let placementVersion: UInt64
    let visibleTilesCount: Int
    let readyTilesCount: Int
    let requestedTilesCount: Int
    let renderedTilesCount: Int
}
