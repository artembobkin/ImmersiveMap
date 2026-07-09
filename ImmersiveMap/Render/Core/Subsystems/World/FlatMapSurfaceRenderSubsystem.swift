// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class FlatMapSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "FlatMapSurface"

    private let tilePipeline: TilePipeline
    private let separateRoadRenderingMinimumZoom: Int
    private let debugOverlayControls: DebugOverlayControlState

    init(tilePipeline: TilePipeline,
         separateRoadRenderingMinimumZoom: Int,
         debugOverlayControls: DebugOverlayControlState) {
        self.tilePipeline = tilePipeline
        self.separateRoadRenderingMinimumZoom = separateRoadRenderingMinimumZoom
        self.debugOverlayControls = debugOverlayControls
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .flatMapSurface,
              frameContext.renderSurfaceMode == .flat else {
            return
        }

        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  separateRoadRenderingMinimumZoom: separateRoadRenderingMinimumZoom,
                                  placeTilesContext: frameContext.sharedState.tilePlacementState.placeTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  tilePipeline: tilePipeline,
                                  isWireframeEnabled: debugOverlayControls.snapshot().wireframeEnabled)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
