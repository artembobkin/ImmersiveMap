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
    /// The coverage targets: the tiles the frame draws, at the zoom their
    /// place on screen wants (`TileCulling`), finest first.
    let visibleTiles: [VisibleTile]
    /// Flat-mode horizon backdrop: a few very coarse tiles covering the
    /// frustum footprint whole, so the ground is painted up to the true
    /// horizon whatever the coverage places. Labels are not extracted from
    /// them. Empty on the globe.
    let backdropTiles: [VisibleTile]
    let tileZoomLevel: Int
    let coverageVersion: UInt64
    /// The flat map's depth bands, nearest first (`FlatDepthRuleCoverage`):
    /// each rule's zoom, depth and tile count. Empty on the globe.
    let flatDepthBands: [FlatDepthBand]
    /// The targets a rasterized rule placed, with the texels a side their
    /// picture is rendered at (`TileRasterizer`). Empty on the globe.
    let rasterizedTiles: [VisibleTile: Int]

    init(centerWorldMercator: SIMD2<Double>,
         center: Center,
         visibleTiles: [VisibleTile],
         backdropTiles: [VisibleTile],
         tileZoomLevel: Int,
         coverageVersion: UInt64,
         flatDepthBands: [FlatDepthBand] = [],
         rasterizedTiles: [VisibleTile: Int] = [:]) {
        self.centerWorldMercator = centerWorldMercator
        self.center = center
        self.visibleTiles = visibleTiles
        self.backdropTiles = backdropTiles
        self.tileZoomLevel = tileZoomLevel
        self.coverageVersion = coverageVersion
        self.flatDepthBands = flatDepthBands
        self.rasterizedTiles = rasterizedTiles
    }
}
