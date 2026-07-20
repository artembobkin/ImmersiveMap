// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  VisibleContentState.swift
//  ImmersiveMap
//

import simd

struct VisibleContentState {
    static let empty = VisibleContentState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                           center: Center(tileX: 0, tileY: 0),
                                           visibleTiles: [],
                                           backdropTiles: [],
                                           tileZoomLevel: 0,
                                           coverageVersion: 0)

    let centerWorldMercator: SIMD2<Double>
    let center: Center
    let visibleTiles: [VisibleTile]
    /// Подложка горизонта плоского режима: несколько очень грубых тайлов,
    /// покрывающих след фрустума без радиусного клампа, - красят землю до
    /// настоящего горизонта, чтобы край покрытия не «дорисовывался» при смене
    /// целевого зума. Лейблы из них не извлекаются. На глобусе пусто.
    let backdropTiles: [VisibleTile]
    let tileZoomLevel: Int
    let coverageVersion: UInt64
}
