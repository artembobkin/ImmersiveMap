// Copyright (c) 2025-2026 Artem Bobkin.
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
                     textAtlas: TextAtlas,
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
                                                 textAtlas: textAtlas,
                                                 frameContext: frameContext,
                                                 placeTiles: frameContext.state[TilePlacementState.self].placeTilesContext.tilePlacements)
        }
        if controls.tileGridEnabled {
            debugOverlayRenderer.drawTileGridOverlay(renderEncoder: renderEncoder,
                                                     polygonPipeline: polygonPipeline,
                                                     textAtlas: textAtlas,
                                                     frameContext: frameContext,
                                                     placeTiles: frameContext.state[TilePlacementState.self].placeTilesContext.tilePlacements,
                                                     density: controls.tileGridDensity)
        }
        if controls.roadLabelTilesEnabled {
            let activeTiles = Set(frameContext.state[RoadLabelState.self].activeRoadLabelTiles)
            let roadLabelPlaceTiles = frameContext.state[TilePlacementState.self].placeTilesContext.tilePlacements.filter { placeTile in
                activeTiles.contains(placeTile.placeIn)
            }
            debugOverlayRenderer.drawRoadLabelTileOverlay(renderEncoder: renderEncoder,
                                                          polygonPipeline: polygonPipeline,
                                                          frameContext: frameContext,
                                                          placeTiles: roadLabelPlaceTiles)
        }
        if controls.baseLabelBoundsEnabled || controls.roadLabelBoundsEnabled {
            debugOverlayRenderer.drawLabelBoundsOverlay(renderEncoder: renderEncoder,
                                                        polygonPipeline: polygonPipeline,
                                                        frameContext: frameContext,
                                                        boxesState: frameContext.state[BaseLabelDebugBoxesState.self])
        }
    }
}
