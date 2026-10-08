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
                                           tileZoomLevel: 0,
                                           coverageVersion: 0)

    let centerWorldMercator: SIMD2<Double>
    let center: Center
    /// The coverage targets: the tiles the frame draws, at the zoom their
    /// place on screen wants (`TileCulling`), finest first.
    let visibleTiles: [VisibleTile]
    let tileZoomLevel: Int
    let coverageVersion: UInt64
    /// The ring rules' bands, nearest first (`FlatRingRuleCoverage` on the
    /// plane, `GlobeTileCoverage` on the sphere): each rule's zoom, last
    /// ring and tile count.
    let flatRingBands: [FlatRingBand]
    /// The targets a rule that draws no lines placed
    /// (`FlatRingRule.drawsLines`), on either surface.
    let linelessTiles: Set<VisibleTile>
    /// The targets a rule that draws no labels placed
    /// (`FlatRingRule.drawsLabels`), on either surface.
    let unlabelledTiles: Set<VisibleTile>
    /// The targets a rule that draws its ground from a texture placed
    /// (`FlatRingRule.rasterSize`), with how each is baked, on either
    /// surface. Such a target's ground is its raster or nothing, and its
    /// vector tile is wanted only for what it draws over the raster (its
    /// lines and labels) or to bake the raster from.
    let rasterTiles: [VisibleTile: RasterTileSpec]

    init(centerWorldMercator: SIMD2<Double>,
         center: Center,
         visibleTiles: [VisibleTile],
         tileZoomLevel: Int,
         coverageVersion: UInt64,
         flatRingBands: [FlatRingBand] = [],
         linelessTiles: Set<VisibleTile> = [],
         unlabelledTiles: Set<VisibleTile> = [],
         rasterTiles: [VisibleTile: RasterTileSpec] = [:]) {
        self.centerWorldMercator = centerWorldMercator
        self.center = center
        self.visibleTiles = visibleTiles
        self.tileZoomLevel = tileZoomLevel
        self.coverageVersion = coverageVersion
        self.flatRingBands = flatRingBands
        self.linelessTiles = linelessTiles
        self.unlabelledTiles = unlabelledTiles
        self.rasterTiles = rasterTiles
    }

    /// Whether a raster target draws anything from its vector tile: its
    /// lines or its labels.
    func rasterTargetWantsVector(_ target: VisibleTile) -> Bool {
        linelessTiles.contains(target) == false || unlabelledTiles.contains(target) == false
    }
}
