// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class GlobeSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeSurface"

    private let globeDepthState: MTLDepthStencilState
    private let globePipeline: GlobePipeline
    private let placeholderPipeline: GlobePipeline
    private let mapSurfaceGridBuffers: MapSurfaceGridBuffers
    private let tilesTexture: TileAtlasTexture
    private let debugOverlayControls: DebugOverlayControlState

    init(globeDepthState: MTLDepthStencilState,
         globePipeline: GlobePipeline,
         placeholderPipeline: GlobePipeline,
         mapSurfaceGridBuffers: MapSurfaceGridBuffers,
         tilesTexture: TileAtlasTexture,
         debugOverlayControls: DebugOverlayControlState) {
        self.globeDepthState = globeDepthState
        self.globePipeline = globePipeline
        self.placeholderPipeline = placeholderPipeline
        self.mapSurfaceGridBuffers = mapSurfaceGridBuffers
        self.tilesTexture = tilesTexture
        self.debugOverlayControls = debugOverlayControls
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
        // Blank map under the atlas. Drawn first and with the same depth state,
        // so tiles land on top of it: their grid is finer, which puts them at
        // or in front of this depth, never behind it.
        GlobeSurfaceDrawer.drawPlaceholder(renderEncoder: encoder,
                                           cameraUniform: frameContext.cameraUniform,
                                           globe: frameContext.globeRenderUniform,
                                           earthScene: frameContext.earthSceneUniform,
                                           placeholderPipeline: placeholderPipeline,
                                           mapSurfaceGridBuffers: mapSurfaceGridBuffers,
                                           horizonFog: horizonFog,
                                           fillColor: SIMD4<Float>(Float(mapClearColor.x),
                                                                   Float(mapClearColor.y),
                                                                   Float(mapClearColor.z),
                                                                   Float(mapClearColor.w)))
        GlobeSurfaceDrawer.draw(renderEncoder: encoder,
                                cameraUniform: frameContext.cameraUniform,
                                globe: frameContext.globeRenderUniform,
                                earthScene: frameContext.earthSceneUniform,
                                globePipeline: globePipeline,
                                mapSurfaceGridBuffers: mapSurfaceGridBuffers,
                                tilesTexture: tilesTexture,
                                horizonFog: horizonFog,
                                isWireframeEnabled: debugOverlayControls.snapshot().wireframeEnabled)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
