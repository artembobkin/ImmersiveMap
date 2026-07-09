// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct TerrainTileCacheKey: Hashable {
    let sourceID: String
    private let sourceBaseURL: String
    private let sourceEncoding: ImmersiveMapTerrainSource.Encoding
    private let sourceDatum: ImmersiveMapTerrainSource.Datum
    let tile: Tile
    let renderSurfaceMode: ViewMode
    let meshResolution: Int
    private let exaggeration: UInt32
    private let heightScale: UInt32
    private let globeRadius: UInt32?

    init(source: ImmersiveMapTerrainSource,
         tile: Tile,
         renderSurfaceMode: ViewMode,
         meshResolution: Int,
         exaggeration: Float,
         heightScale: Float,
         globeRadius: Float) {
        self.sourceID = source.id
        self.sourceBaseURL = source.baseURL.absoluteString
        self.sourceEncoding = source.encoding
        self.sourceDatum = source.datum
        self.tile = tile
        self.renderSurfaceMode = renderSurfaceMode
        self.meshResolution = max(meshResolution, 2)
        self.exaggeration = exaggeration.bitPattern
        self.heightScale = heightScale.bitPattern
        self.globeRadius = renderSurfaceMode == .spherical ? globeRadius.bitPattern : nil
    }
}

struct TerrainTileRequestPlan: Equatable {
    let visibleTile: VisibleTile
    let sourceTile: Tile
    let cacheKey: TerrainTileCacheKey
}

enum TerrainTileRequestPlanner {
    static func plan(visibleTile: VisibleTile,
                     terrain: ImmersiveMapSettings.TerrainSettings,
                     renderSurfaceMode: ViewMode,
                     globeRadius: Float,
                     heightScale: Float) -> TerrainTileRequestPlan? {
        guard terrain.isEnabled,
              let source = terrain.source else {
            return nil
        }

        let sourceZoom = resolvedSourceZoom(visibleTileZoom: visibleTile.z,
                                            terrainMaximumZoom: terrain.maximumZoomLevel,
                                            sourceMaximumZoom: source.maximumZoomLevel)
        guard let sourceTile = visibleTile.tile.findParentTile(atZoom: sourceZoom) else {
            return nil
        }

        let cacheKey = TerrainTileCacheKey(source: source,
                                           tile: sourceTile,
                                           renderSurfaceMode: renderSurfaceMode,
                                           meshResolution: terrain.meshResolution,
                                           exaggeration: terrain.exaggeration,
                                           heightScale: heightScale,
                                           globeRadius: globeRadius)
        return TerrainTileRequestPlan(visibleTile: visibleTile,
                                      sourceTile: sourceTile,
                                      cacheKey: cacheKey)
    }

    static func uniquePlans(visibleTiles: [VisibleTile],
                            terrain: ImmersiveMapSettings.TerrainSettings,
                            renderSurfaceMode: ViewMode,
                            globeRadius: Float,
                            heightScale: Float) -> [TerrainTileRequestPlan] {
        var seenKeys = Set<TerrainTileCacheKey>()
        var plans: [TerrainTileRequestPlan] = []
        plans.reserveCapacity(visibleTiles.count)

        for visibleTile in visibleTiles {
            guard let plan = plan(visibleTile: visibleTile,
                                  terrain: terrain,
                                  renderSurfaceMode: renderSurfaceMode,
                                  globeRadius: globeRadius,
                                  heightScale: heightScale),
                  seenKeys.insert(plan.cacheKey).inserted else {
                continue
            }
            plans.append(plan)
        }

        return plans
    }

    static func drawPlans(visibleTiles: [VisibleTile],
                          terrain: ImmersiveMapSettings.TerrainSettings,
                          renderSurfaceMode: ViewMode,
                          globeRadius: Float,
                          heightScale: Float) -> [TerrainTileRequestPlan] {
        var seenKeys = Set<TerrainTileDrawPlanKey>()
        var plans: [TerrainTileRequestPlan] = []
        plans.reserveCapacity(visibleTiles.count)

        for visibleTile in visibleTiles {
            guard let plan = plan(visibleTile: visibleTile,
                                  terrain: terrain,
                                  renderSurfaceMode: renderSurfaceMode,
                                  globeRadius: globeRadius,
                                  heightScale: heightScale),
                  seenKeys.insert(TerrainTileDrawPlanKey(cacheKey: plan.cacheKey,
                                                         loop: visibleTile.loop)).inserted else {
                continue
            }
            plans.append(plan)
        }

        return plans
    }

    private static func resolvedSourceZoom(visibleTileZoom: Int,
                                           terrainMaximumZoom: Int,
                                           sourceMaximumZoom: Int) -> Int {
        max(0, min(visibleTileZoom, terrainMaximumZoom, sourceMaximumZoom))
    }
}

private struct TerrainTileDrawPlanKey: Hashable {
    let cacheKey: TerrainTileCacheKey
    let loop: Int8
}
