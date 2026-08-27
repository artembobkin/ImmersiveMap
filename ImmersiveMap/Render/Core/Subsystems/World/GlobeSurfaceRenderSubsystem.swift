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
        let atmosphere = GlobeAtmosphereUniform.make(settings: frameContext.services.settings.scene.atmosphere)
        let tone = GlobeSurfaceToneUniform.make(zoom: frameContext.zoom)
        // Blank map in every slot the placements leave unpainted, drawn first
        // and with the same depth state. Each fill is the slot its tile will
        // draw, on the same grid: the tile replaces it at identical depth, so
        // nothing coarser sits under the tiles to poke through their mesh.
        let uncoveredSlots = frameContext.sharedState.tilePlacementState.tileAtlasPlaceTilesContext.uncoveredSlots
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
                                                slots: uncoveredSlots)
        GlobeSurfaceDrawer.draw(renderEncoder: encoder,
                                cameraUniform: frameContext.cameraUniform,
                                globe: frameContext.globeRenderUniform,
                                earthScene: frameContext.earthSceneUniform,
                                globePipeline: globePipeline,
                                mapSurfaceGridBuffers: mapSurfaceGridBuffers,
                                tilesTexture: tilesTexture,
                                horizonFog: horizonFog,
                                atmosphere: atmosphere,
                                tone: tone,
                                isWireframeEnabled: debugOverlayControls.snapshot().wireframeEnabled)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
