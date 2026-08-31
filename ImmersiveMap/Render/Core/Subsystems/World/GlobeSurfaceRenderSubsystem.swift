// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class GlobeSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeSurface"

    private let globeDepthState: MTLDepthStencilState
    private let placeholderPipeline: GlobePipeline
    private let mapSurfaceGridBuffers: MapSurfaceGridBuffers

    init(globeDepthState: MTLDepthStencilState,
         placeholderPipeline: GlobePipeline,
         mapSurfaceGridBuffers: MapSurfaceGridBuffers) {
        self.globeDepthState = globeDepthState
        self.placeholderPipeline = placeholderPipeline
        self.mapSurfaceGridBuffers = mapSurfaceGridBuffers
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .globeSurface,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        encoder.setDepthStencilState(globeDepthState)
        let mapClearColor = frameContext.services.settings.scene.mapClearColor
        let horizonFog = HorizonFogUniform.make(transition: frameContext.transition,
                                                cameraEye: frameContext.cameraUniform.eye,
                                                mapClearColor: mapClearColor)
        let atmosphere = GlobeAtmosphereUniform.make(settings: frameContext.services.settings.scene.atmosphere,
                                                     earthScene: frameContext.earthSceneUniform,
                                                     globe: frameContext.globeRenderUniform)
        let tone = GlobeSurfaceToneUniform.make(zoom: frameContext.zoom)
        // Blank map under the surface: every target slot gets one. It is
        // what writes the surface depth and paints the base the tile geometry
        // (drawn on the sphere by the next layer) lands on, whether or not
        // its tile has arrived.
        let placeholderSlots = frameContext.sharedState.tilePlacementState.globeSurfaceSlots
        let litInline = !GlobeSurfaceLightingPath.isDeferred(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                             transition: frameContext.globeRenderUniform.transition,
                                                             zoom: frameContext.zoom)
        GlobeSurfaceDrawer.drawPlaceholderTiles(renderEncoder: encoder,
                                                cameraUniform: frameContext.cameraUniform,
                                                globe: frameContext.globeRenderUniform,
                                                earthScene: frameContext.earthSceneUniform,
                                                placeholderPipeline: placeholderPipeline,
                                                mapSurfaceGridBuffers: mapSurfaceGridBuffers,
                                                horizonFog: horizonFog,
                                                atmosphere: atmosphere,
                                                tone: tone,
                                                fillColor: SIMD4<Float>(Float(mapClearColor.x),
                                                                        Float(mapClearColor.y),
                                                                        Float(mapClearColor.z),
                                                                        Float(mapClearColor.w)),
                                                slots: placeholderSlots,
                                                litInline: litInline,
                                                pureSphere: GlobeSphereVertexPath.isPureSphere(
                                                    renderSurfaceMode: frameContext.renderSurfaceMode,
                                                    transition: frameContext.globeRenderUniform.transition),
                                                globeFrame: GlobeFrameConstantsUniform.make(globe: frameContext.globeRenderUniform))
    }

    func handleMemoryWarning() {}

    func evict() {}
}
