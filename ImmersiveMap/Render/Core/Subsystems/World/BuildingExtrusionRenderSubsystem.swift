// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Draws the extruded buildings of flat mode: opaque geometry straight into
/// the world pass, before the ground, which then fails its depth test under
/// them. Always solid; there is no translucent path.
final class BuildingExtrusionRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "BuildingExtrusion"

    private let extrudedTilePipeline: ExtrudedTilePipeline
    /// Depth-only state of the shadow-caster pass (no stencil attachment there).
    private let extrudedDepthState: MTLDepthStencilState
    /// World-pass buildings: scene depth plus the tile-priority stencil test.
    private let extrudedStencilTestState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture

    init(extrudedTilePipeline: ExtrudedTilePipeline,
         extrudedDepthState: MTLDepthStencilState,
         extrudedStencilTestState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture) {
        self.extrudedTilePipeline = extrudedTilePipeline
        self.extrudedDepthState = extrudedDepthState
        self.extrudedStencilTestState = extrudedStencilTestState
        self.depthDisabledState = depthDisabledState
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    /// With extrusion off the tiles carry no building geometry: the layer
    /// is planned out of the world pass rather than encoding its state for
    /// nothing.
    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.buildingExtrusionEnabled = settings.style.buildingExtrusionEnabled
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .flat else {
            return
        }

        if layer == .shadowCasters {
            guard let shadowState = frameContext.shadowFrameState else { return }
            // The casters are the building coverage, the same partition the
            // world pass draws, so a building casts exactly once.
            BuildingExtrusionDrawer.drawShadowCasters(
                renderEncoder: encoder,
                lightProjectionView: shadowState.lightProjectionView,
                placeTilesContext: frameContext.sharedState.tilePlacementState.buildingPlaceTilesContext,
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
        BuildingExtrusionDrawer.drawBuildings(renderEncoder: encoder,
                                              cameraUniform: frameContext.cameraUniform,
                                              shadowBinding: shadowBinding,
                                              placeTilesContext: frameContext.sharedState.tilePlacementState.buildingPlaceTilesContext,
                                              flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                              extrudedTilePipeline: extrudedTilePipeline,
                                              extrudedStencilTestState: extrudedStencilTestState,
                                              depthDisabledState: depthDisabledState)
    }
}
