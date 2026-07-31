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
    /// Flat-mode horizon backdrop: a few very coarse tiles
    /// covering the frustum footprint without the radius clamp - they paint the ground up to
    /// the true horizon so the coverage edge isn't "drawn in" when the target
    /// zoom changes. Labels are not extracted from them. Empty on the globe.
    let backdropTiles: [VisibleTile]
    let tileZoomLevel: Int
    let coverageVersion: UInt64
}
