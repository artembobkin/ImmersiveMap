// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Draws the globe's tiles as geometry on the sphere: the ground layer of
/// every placement, projected per vertex through the surface morph and lit
/// like the placeholder grid the `globeSurface` layer painted just before.
/// The grid wrote the surface depth, which routes, scene models and label
/// occlusion keep testing against; this geometry neither tests nor writes
/// depth. Its extent is decided by the clip distances (the placeIn slot and
/// the sphere as an occluder, `GlobeOcclusion.h`: whatever the planet hides
/// from the eye is clipped, on the pure sphere the horizon and, while the
/// sphere unfurls, the far side morphing through the planet's interior) and
/// by back-face culling: every tile triangle is wound counter-clockwise in
/// render space, so the far side of the pure sphere is clockwise on screen.
/// Nothing drawn before it on the sphere stands in front of it, so a depth
/// test would only compare it with the grid, a different chord
/// approximation of the same sphere, and z-fight.
final class GlobeVectorSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeVectorSurface"

    private let pipeline: TilePipeline
    private let depthDisabledState: MTLDepthStencilState
    private let opaqueDepthState: MTLDepthStencilState
    private let translucentDepthState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState

    init(pipeline: TilePipeline,
         depthDisabledState: MTLDepthStencilState,
         opaqueDepthState: MTLDepthStencilState,
         translucentDepthState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState) {
        self.pipeline = pipeline
        self.depthDisabledState = depthDisabledState
        self.opaqueDepthState = opaqueDepthState
        self.translucentDepthState = translucentDepthState
        self.debugOverlayControls = debugOverlayControls
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .globeVectorSurface,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        let settings = frameContext.services.settings
        let horizonFog = HorizonFogUniform.make(transition: frameContext.transition,
                                                geometryTransition: frameContext.globeRenderUniform.transition,
                                                cameraEye: frameContext.cameraUniform.eye,
                                                mapClearColor: settings.scene.mapClearColor,
                                                globeRadius: frameContext.globeRenderUniform.radius,
                                                hazeEnabled: settings.scene.space.isTransparent == false)
        encoder.setDepthStencilState(depthDisabledState)
        GlobeVectorSurfaceDrawer.draw(renderEncoder: encoder,
                                      cameraUniform: frameContext.cameraUniform,
                                      globe: frameContext.globeRenderUniform,
                                      horizonFog: horizonFog,
                                      cameraZoom: frameContext.zoom,
                                      pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                      drawableHeightPx: Float(frameContext.drawSize.height),
                                      renderMapSize: frameContext.resolvedPresentation.renderNormalizationState.flatRenderMapSize,
                                      placeTilesContext: frameContext.sharedState.tilePlacementState.placeTilesContext,
                                      pipeline: pipeline,
                                      opaqueDepthState: opaqueDepthState,
                                      translucentDepthState: translucentDepthState,
                                      depthDisabledState: depthDisabledState,
                                      isWireframeEnabled: debugOverlayControls.snapshot().wireframeEnabled,
                                      pureSphere: GlobeSphereVertexPath.isPureSphere(
                                          renderSurfaceMode: frameContext.renderSurfaceMode,
                                          transition: frameContext.globeRenderUniform.transition),
                                      globeFrame: GlobeFrameConstantsUniform.make(globe: frameContext.globeRenderUniform,
                                                                 cameraMatrix: frameContext.cameraUniform.matrix))
    }

    func handleMemoryWarning() {}

    func evict() {}
}
