// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Draws the extruded buildings of flat mode. Solid path: opaque geometry
/// straight into the world pass. Composited path (translucent and the
/// solidAtHighZoom zoom transition): the same opaque geometry goes into the
/// offscreen building image (the `.buildingImage` layer), and in the world pass
/// the image is composited over the map with a single fullscreen blend using the
/// frame alpha, so each pixel is tinted exactly once, with no seams between surfaces.
final class BuildingExtrusionRenderSubsystem: RenderSubsystem {
    let name: String = "BuildingExtrusion"

    private let buildingImageTextureProvider: () -> MTLTexture?
    private let extrudedTilePipeline: ExtrudedTilePipeline
    private let extrudedDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let compositeDepthResetState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private let supportsFramebufferFetch: Bool

    init(buildingImageTextureProvider: @escaping () -> MTLTexture?,
         extrudedTilePipeline: ExtrudedTilePipeline,
         extrudedDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         compositeDepthResetState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture,
         supportsFramebufferFetch: Bool) {
        self.buildingImageTextureProvider = buildingImageTextureProvider
        self.extrudedTilePipeline = extrudedTilePipeline
        self.extrudedDepthState = extrudedDepthState
        self.depthDisabledState = depthDisabledState
        self.compositeDepthResetState = compositeDepthResetState
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
        self.supportsFramebufferFetch = supportsFramebufferFetch
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .flat else {
            return
        }

        if layer == .shadowCasters {
            guard let shadowState = frameContext.shadowFrameState else { return }
            // Visible placements plus the off-screen sun-ward strip: buildings
            // just past the frustum edge still cast into the frame, and without
            // them their shadows pop in and out while the camera pans.
            let tilePlacementState = frameContext.sharedState.tilePlacementState
            let casterPlacements = tilePlacementState.placeTilesContext.tilePlacements
                + tilePlacementState.shadowCasterPlaceTilesContext.tilePlacements
            BuildingExtrusionDrawer.drawShadowCasters(
                renderEncoder: encoder,
                lightProjectionViews: shadowState.lightProjectionViews,
                placeTilesContext: PlaceTilesContext(tilePlacements: casterPlacements),
                flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                extrudedTilePipeline: extrudedTilePipeline,
                extrudedDepthState: extrudedDepthState)
            return
        }

        // Mode and alpha are read from the frame settings: changing them applies
        // on the fly, without recreating the renderer (see planner). The per-frame
        // path is resolved the same way as in RenderPassGraph.plan.
        let style = frameContext.services.settings.style
        let path = BuildingExtrusionPathResolver.resolve(style: style, zoom: frameContext.zoom)
        let usesInPassImage = BuildingExtrusionPathResolver.usesInPassBuildingImage(
            style: style,
            zoom: frameContext.zoom,
            renderSurfaceMode: frameContext.renderSurfaceMode,
            supportsFramebufferFetch: supportsFramebufferFetch
        )
        switch layer {
        case .buildingImage:
            guard case .composited = path else { return }
            drawBuildings(encoder: encoder,
                          frameContext: frameContext,
                          intoImageAttachment: usesInPassImage)
        case .buildingExtrusion:
            switch path {
            case .solid:
                drawBuildings(encoder: encoder, frameContext: frameContext)
            case .composited(let alpha):
                if usesInPassImage {
                    BuildingExtrusionDrawer.drawCompositeFetch(renderEncoder: encoder,
                                                               alpha: alpha,
                                                               extrudedTilePipeline: extrudedTilePipeline,
                                                               compositeDepthResetState: compositeDepthResetState,
                                                               depthDisabledState: depthDisabledState)
                } else {
                    guard let buildingImageTexture = buildingImageTextureProvider() else { return }
                    BuildingExtrusionDrawer.drawComposite(renderEncoder: encoder,
                                                          buildingImageTexture: buildingImageTexture,
                                                          alpha: alpha,
                                                          extrudedTilePipeline: extrudedTilePipeline,
                                                          depthDisabledState: depthDisabledState)
                }
            }
        default:
            return
        }
    }

    func handleMemoryWarning() {}

    func evict() {}

    private func drawBuildings(encoder: MTLRenderCommandEncoder,
                               frameContext: FrameContext,
                               intoImageAttachment: Bool = false) {
        let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                          shadowMapTexture: shadowMapTextureProvider(),
                                                          fallbackTexture: shadowFallbackTexture)
        BuildingExtrusionDrawer.drawBuildings(renderEncoder: encoder,
                                              cameraUniform: frameContext.cameraUniform,
                                              shadowBinding: shadowBinding,
                                              placeTilesContext: frameContext.sharedState.tilePlacementState.placeTilesContext,
                                              flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                              extrudedTilePipeline: extrudedTilePipeline,
                                              extrudedDepthState: extrudedDepthState,
                                              depthDisabledState: depthDisabledState,
                                              intoImageAttachment: intoImageAttachment)
    }
}
