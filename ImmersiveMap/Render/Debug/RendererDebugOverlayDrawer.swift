// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MetalKit
import simd

enum RendererDebugOverlayDrawer {
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     frameContext: FrameContext,
                     polygonPipeline: PolygonsPipeline,
                     debugOverlayRenderer: DebugOverlayRenderer,
                     textRenderer: TextRenderer,
                     controls: DebugOverlayControlSnapshot) {
        if controls.axesEnabled {
            debugOverlayRenderer.drawAxes(renderEncoder: renderEncoder,
                                          polygonPipeline: polygonPipeline,
                                          cameraUniform: CameraUniform(matrix: frameContext.cameraMatrices.projectionView,
                                                                       eye: frameContext.cameraEye,
                                                                       padding: 0.0))
        }
        if controls.tileLayersEnabled {
            debugOverlayRenderer.drawTileOverlay(renderEncoder: renderEncoder,
                                                 polygonPipeline: polygonPipeline,
                                                 textRenderer: textRenderer,
                                                 frameContext: frameContext,
                                                 placeTiles: frameContext.sharedState.placeTileTrackingState.placeTiles)
        }
        if controls.roadLabelTilesEnabled {
            let activeTiles = Set(frameContext.sharedState.roadLabelState.activeRoadLabelTiles)
            let roadLabelPlaceTiles = frameContext.sharedState.placeTileTrackingState.placeTiles.filter { placeTile in
                activeTiles.contains(placeTile.placeIn)
            }
            debugOverlayRenderer.drawRoadLabelTileOverlay(renderEncoder: renderEncoder,
                                                          polygonPipeline: polygonPipeline,
                                                          frameContext: frameContext,
                                                          placeTiles: roadLabelPlaceTiles)
        }
    }

    static func makeAtlasDebugLines(summary: TileAtlasDebugSummary?) -> [String] {
        guard let summary else { return [] }

        let depthCounts = TileAtlasSlotDepth.allCases
            .map { "d\($0.rawValue):\(summary.slotCount(depth: $0))" }
            .joined(separator: " ")
        return [
            "atlas pages:\(summary.pageCount) alloc:\(summary.allocationCount) down:\(summary.downgradedAllocationCount) skip:\(summary.skippedAllocationCount)",
            "atlas \(depthCounts)"
        ]
    }
}
