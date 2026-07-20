// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class GlobeSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeSurface"

    private let globeDepthState: MTLDepthStencilState
    private let globePipeline: GlobePipeline
    private let mapSurfaceGridBuffers: MapSurfaceGridBuffers
    private let tilesTexture: TileAtlasTexture
    private let debugOverlayControls: DebugOverlayControlState

    init(globeDepthState: MTLDepthStencilState,
         globePipeline: GlobePipeline,
         mapSurfaceGridBuffers: MapSurfaceGridBuffers,
         tilesTexture: TileAtlasTexture,
         debugOverlayControls: DebugOverlayControlState) {
        self.globeDepthState = globeDepthState
        self.globePipeline = globePipeline
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
        GlobeSurfaceDrawer.draw(renderEncoder: encoder,
                                cameraUniform: frameContext.cameraUniform,
                                globe: frameContext.globeRenderUniform,
                                earthScene: frameContext.earthSceneUniform,
                                nightLightsAtlasState: frameContext.sharedState.nightLightsAtlasState,
                                globePipeline: globePipeline,
                                mapSurfaceGridBuffers: mapSurfaceGridBuffers,
                                tilesTexture: tilesTexture,
                                isWireframeEnabled: debugOverlayControls.snapshot().wireframeEnabled)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
