// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Draws the globe's tiles as geometry on the sphere: the ground layer of
/// every placement, projected per vertex through the surface morph and lit
/// like the placeholder grid the `globeSurface` layer painted just before.
/// The grid wrote the depth; this geometry only tests against it (lifted
/// off the sphere, see `GlobeSurfaceLift`) and blends over it, so routes,
/// scene models and label occlusion keep the surface depth they had.
final class GlobeVectorSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeVectorSurface"

    private let pipeline: TilePipeline
    private let surfaceDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState
    private let renderPath: GlobeSurfaceRenderPath

    init(pipeline: TilePipeline,
         surfaceDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         renderPath: GlobeSurfaceRenderPath) {
        self.pipeline = pipeline
        self.surfaceDepthState = surfaceDepthState
        self.depthDisabledState = depthDisabledState
        self.debugOverlayControls = debugOverlayControls
        self.renderPath = renderPath
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .globeVectorSurface,
              frameContext.renderSurfaceMode == .spherical,
              renderPath == .vector else {
            return
        }

        let settings = frameContext.services.settings
        let horizonFog = HorizonFogUniform.make(transition: frameContext.transition,
                                                cameraEye: frameContext.cameraUniform.eye,
                                                mapClearColor: settings.scene.mapClearColor)
        let atmosphere = GlobeAtmosphereUniform.make(settings: settings.scene.atmosphere,
                                                     earthScene: frameContext.earthSceneUniform,
                                                     globe: frameContext.globeRenderUniform)
        encoder.setDepthStencilState(surfaceDepthState)
        GlobeVectorSurfaceDrawer.draw(renderEncoder: encoder,
                                      cameraUniform: frameContext.cameraUniform,
                                      globe: frameContext.globeRenderUniform,
                                      earthScene: frameContext.earthSceneUniform,
                                      atmosphere: atmosphere,
                                      tone: GlobeSurfaceToneUniform.make(zoom: frameContext.zoom),
                                      horizonFog: horizonFog,
                                      cameraZoom: frameContext.zoom,
                                      pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                      drawableHeightPx: Float(frameContext.drawSize.height),
                                      renderMapSize: frameContext.resolvedPresentation.renderNormalizationState.flatRenderMapSize,
                                      placeTilesContext: frameContext.sharedState.tilePlacementState.placeTilesContext,
                                      pipeline: pipeline,
                                      isWireframeEnabled: debugOverlayControls.snapshot().wireframeEnabled)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
