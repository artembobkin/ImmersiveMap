// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class BuildingExtrusionRenderSubsystem: RenderSubsystem {
    let name: String = "BuildingExtrusion"

    private let buildingExtrusionAlpha: Float
    private let buildingWinnerIDTextureProvider: () -> MTLTexture?
    private let extrudedTilePipeline: ExtrudedTilePipeline
    private let extrudedColorPassDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    init(buildingExtrusionAlpha: Float,
         buildingWinnerIDTextureProvider: @escaping () -> MTLTexture?,
         extrudedTilePipeline: ExtrudedTilePipeline,
         extrudedColorPassDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.buildingExtrusionAlpha = buildingExtrusionAlpha
        self.buildingWinnerIDTextureProvider = buildingWinnerIDTextureProvider
        self.extrudedTilePipeline = extrudedTilePipeline
        self.extrudedColorPassDepthState = extrudedColorPassDepthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .buildingExtrusion,
              frameContext.renderSurfaceMode == .flat else {
            return
        }

        BuildingExtrusionDrawer.drawColorPass(renderEncoder: encoder,
                                              cameraUniform: frameContext.cameraUniform,
                                              placeTilesContext: frameContext.sharedState.tilePlacementState.placeTilesContext,
                                              flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                              buildingExtrusionAlpha: buildingExtrusionAlpha,
                                              winnerIDTexture: buildingWinnerIDTextureProvider(),
                                              extrudedTilePipeline: extrudedTilePipeline,
                                              extrudedColorPassDepthState: extrudedColorPassDepthState,
                                              depthDisabledState: depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
