// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Draws the extruded buildings of flat mode: opaque geometry straight into
/// the world pass, before the ground, which then fails its depth test under
/// them. Always solid; there is no translucent path. A building a drawn
/// model stands in for (`SceneModelFrameState.replacedBuildings`) is left
/// out of both the world pass and the shadow casters, and its tile still
/// draws in one call, from a working index buffer without it
/// (`HiddenBuildingIndexBuffers`).
final class BuildingExtrusionRenderSubsystem: RenderSubsystem {
    let name: String = "BuildingExtrusion"

    private let extrudedTilePipeline: ExtrudedTilePipeline
    /// Depth-only state of the shadow-caster pass (no stencil attachment there).
    private let extrudedDepthState: MTLDepthStencilState
    /// World-pass buildings: scene depth plus the tile-priority stencil test.
    private let extrudedStencilTestState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private let debugOverlayControls: DebugOverlayControlState
    /// The index buffers the tiles draw from while the frame's models
    /// stand in for some of their buildings, shared by the world pass and
    /// the casters.
    private let hiddenBuildingIndexBuffers = HiddenBuildingIndexBuffers()

    init(extrudedTilePipeline: ExtrudedTilePipeline,
         extrudedDepthState: MTLDepthStencilState,
         extrudedStencilTestState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture,
         debugOverlayControls: DebugOverlayControlState) {
        self.debugOverlayControls = debugOverlayControls
        self.extrudedTilePipeline = extrudedTilePipeline
        self.extrudedDepthState = extrudedDepthState
        self.extrudedStencilTestState = extrudedStencilTestState
        self.depthDisabledState = depthDisabledState
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .flat else {
            return
        }

        if layer == .shadowCasters {
            guard let shadowState = frameContext.shadowFrameState else { return }
            // The casters are the building coverage, the same partition the
            // world pass draws, so a building casts exactly once.
            hiddenBuildingIndexBuffers.update(frameContext.sharedState.sceneModelState.replacedBuildings)
            BuildingExtrusionDrawer.drawShadowCasters(
                renderEncoder: encoder,
                lightProjectionView: shadowState.lightProjectionView,
                placeTilesContext: frameContext.sharedState.tilePlacementState.buildingPlaceTilesContext,
                indexBuffers: hiddenBuildingIndexBuffers,
                flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                extrudedTilePipeline: extrudedTilePipeline,
                extrudedDepthState: extrudedDepthState)
            return
        }

        guard layer == .buildingExtrusion else { return }
        drawBuildings(encoder: encoder, frameContext: frameContext)
    }

    func handleMemoryWarning() {}

    func evict() {}

    private func drawBuildings(encoder: MTLRenderCommandEncoder,
                               frameContext: FrameContext) {
        let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                          shadowMapTexture: shadowMapTextureProvider(),
                                                          fallbackTexture: shadowFallbackTexture)
        hiddenBuildingIndexBuffers.update(frameContext.sharedState.sceneModelState.replacedBuildings)
        BuildingExtrusionDrawer.drawBuildings(renderEncoder: encoder,
                                              cameraUniform: frameContext.cameraUniform,
                                              shadowBinding: shadowBinding,
                                              placeTilesContext: frameContext.sharedState.tilePlacementState.buildingPlaceTilesContext,
                                              indexBuffers: hiddenBuildingIndexBuffers,
                                              flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                              extrudedTilePipeline: extrudedTilePipeline,
                                              extrudedStencilTestState: extrudedStencilTestState,
                                              depthDisabledState: depthDisabledState)
    }
}
