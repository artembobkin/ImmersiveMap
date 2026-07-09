// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class BuildingWinnerRenderSubsystem: RenderSubsystem {
    let name: String = "BuildingWinner"

    private let extrudedTilePipeline: ExtrudedTilePipeline
    private let extrudedDepthState: MTLDepthStencilState

    init(extrudedTilePipeline: ExtrudedTilePipeline,
         extrudedDepthState: MTLDepthStencilState) {
        self.extrudedTilePipeline = extrudedTilePipeline
        self.extrudedDepthState = extrudedDepthState
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .buildingWinner,
              frameContext.renderSurfaceMode == .flat else {
            return
        }

        BuildingExtrusionDrawer.drawWinnerLayer(renderEncoder: encoder,
                                                cameraUniform: frameContext.cameraUniform,
                                                placeTilesContext: frameContext.sharedState.tilePlacementState.placeTilesContext,
                                                flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                                extrudedTilePipeline: extrudedTilePipeline,
                                                extrudedDepthState: extrudedDepthState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
