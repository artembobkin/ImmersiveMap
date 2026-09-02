// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class FlatMapSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "FlatMapSurface"

    private let tilePipeline: TilePipeline
    private let groundOwnerState: MTLDepthStencilState
    private let tileStencilTestState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let separateRoadRenderingMinimumZoom: Int
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture
    private let supportsFramebufferFetch: Bool

    init(tilePipeline: TilePipeline,
         groundOwnerState: MTLDepthStencilState,
         tileStencilTestState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         separateRoadRenderingMinimumZoom: Int,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture,
         supportsFramebufferFetch: Bool) {
        self.tilePipeline = tilePipeline
        self.groundOwnerState = groundOwnerState
        self.tileStencilTestState = tileStencilTestState
        self.depthDisabledState = depthDisabledState
        self.separateRoadRenderingMinimumZoom = separateRoadRenderingMinimumZoom
        self.debugOverlayControls = debugOverlayControls
        self.groundShadowMaskTextureProvider = groundShadowMaskTextureProvider
        self.groundShadowMaskFallbackTexture = groundShadowMaskFallbackTexture
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
        let groundShadowMask = GroundShadowMaskBinding.resolve(frameContext: frameContext,
                                                               maskTexture: groundShadowMaskTextureProvider(),
                                                               fallbackTexture: groundShadowMaskFallbackTexture)
        // The framebuffer-fetch world pass carries a second building
        // attachment; every pipeline in it must declare that attachment to
        // stay pass-compatible (same decision as RenderPassGraph.plan).
        let withBuildingImageAttachment = BuildingExtrusionPathResolver.usesInPassBuildingImage(
            style: frameContext.services.settings.style,
            zoom: frameContext.zoom,
            renderSurfaceMode: frameContext.renderSurfaceMode,
            supportsFramebufferFetch: supportsFramebufferFetch
        )

        // The drawer sets its own depth-stencil states per group: the
        // ground owns the tile-priority stencil (depth tested against the
        // buildings, never written), the road buckets only test it.
        // The horizon backdrop is drawn first: the main coverage lands on top
        // (painter's order), and beyond its edge the ground is painted all the
        // way to the horizon. The backdrop binds the same mask: it lies outside
        // the fitted shadow map, so the mask is lit there.
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  drawableHeightPx: Float(frameContext.drawSize.height),
                                  separateRoadRenderingMinimumZoom: separateRoadRenderingMinimumZoom,
                                  placeTilesContext: tilePlacementState.backdropPlaceTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  horizonFog: horizonFog,
                                  groundShadowMask: groundShadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  isWireframeEnabled: isWireframeEnabled,
                                  withBuildingImageAttachment: withBuildingImageAttachment)
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  drawableHeightPx: Float(frameContext.drawSize.height),
                                  separateRoadRenderingMinimumZoom: separateRoadRenderingMinimumZoom,
                                  placeTilesContext: tilePlacementState.placeTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  horizonFog: horizonFog,
                                  groundShadowMask: groundShadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  isWireframeEnabled: isWireframeEnabled,
                                  withBuildingImageAttachment: withBuildingImageAttachment)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
