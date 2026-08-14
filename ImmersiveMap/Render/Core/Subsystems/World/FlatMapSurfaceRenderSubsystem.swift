// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class FlatMapSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "FlatMapSurface"

    private let tilePipeline: TilePipeline
    private let separateRoadRenderingMinimumZoom: Int
    private let debugOverlayControls: DebugOverlayControlState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private let supportsFramebufferFetch: Bool

    init(tilePipeline: TilePipeline,
         separateRoadRenderingMinimumZoom: Int,
         debugOverlayControls: DebugOverlayControlState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture,
         supportsFramebufferFetch: Bool) {
        self.tilePipeline = tilePipeline
        self.separateRoadRenderingMinimumZoom = separateRoadRenderingMinimumZoom
        self.debugOverlayControls = debugOverlayControls
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
        self.supportsFramebufferFetch = supportsFramebufferFetch
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .flatMapSurface,
              frameContext.renderSurfaceMode == .flat else {
            return
        }

        let tilePlacementState = frameContext.sharedState.tilePlacementState
        let isWireframeEnabled = debugOverlayControls.snapshot().wireframeEnabled
        let horizonFog = HorizonFogUniform.make(transition: frameContext.transition,
                                                cameraEye: frameContext.cameraUniform.eye,
                                                mapClearColor: frameContext.services.settings.scene.mapClearColor)
        let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                          shadowMapTexture: shadowMapTextureProvider(),
                                                          fallbackTexture: shadowFallbackTexture)
        // The framebuffer-fetch world pass carries a second building
        // attachment; every pipeline in it must declare that attachment to
        // stay pass-compatible (same decision as RenderPassGraph.plan).
        let withBuildingImageAttachment = BuildingExtrusionPathResolver.usesInPassBuildingImage(
            style: frameContext.services.settings.style,
            zoom: frameContext.zoom,
            renderSurfaceMode: frameContext.renderSurfaceMode,
            supportsFramebufferFetch: supportsFramebufferFetch
        )

        // The horizon backdrop is drawn first: the main coverage lands on top
        // (painter's order), and beyond its edge the ground is painted all the
        // way to the horizon. The backdrop binds the same shadow state: it lies
        // outside the fitted shadow map, so the UV guard keeps it lit.
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  separateRoadRenderingMinimumZoom: separateRoadRenderingMinimumZoom,
                                  placeTilesContext: tilePlacementState.backdropPlaceTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  horizonFog: horizonFog,
                                  shadowBinding: shadowBinding,
                                  tilePipeline: tilePipeline,
                                  isWireframeEnabled: isWireframeEnabled,
                                  withBuildingImageAttachment: withBuildingImageAttachment)
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  separateRoadRenderingMinimumZoom: separateRoadRenderingMinimumZoom,
                                  placeTilesContext: tilePlacementState.placeTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  horizonFog: horizonFog,
                                  shadowBinding: shadowBinding,
                                  tilePipeline: tilePipeline,
                                  isWireframeEnabled: isWireframeEnabled,
                                  withBuildingImageAttachment: withBuildingImageAttachment)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
