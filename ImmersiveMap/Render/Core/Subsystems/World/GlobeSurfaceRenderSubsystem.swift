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
    private let renderPath: GlobeSurfaceRenderPath

    init(globeDepthState: MTLDepthStencilState,
         globePipeline: GlobePipeline,
         placeholderPipeline: GlobePipeline,
         mapSurfaceGridBuffers: MapSurfaceGridBuffers,
         tilesTexture: TileAtlasTexture,
         debugOverlayControls: DebugOverlayControlState,
         renderPath: GlobeSurfaceRenderPath = .vector) {
        self.globeDepthState = globeDepthState
        self.globePipeline = globePipeline
        self.placeholderPipeline = placeholderPipeline
        self.mapSurfaceGridBuffers = mapSurfaceGridBuffers
        self.tilesTexture = tilesTexture
        self.debugOverlayControls = debugOverlayControls
        self.renderPath = renderPath
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
        // Blank map under the surface, drawn first and with the same depth
        // state. On the vector path every target slot gets one: it is what
        // writes the surface depth and paints the base the tile geometry
        // (drawn on the sphere by the next layer) lands on, whether or not
        // its tile has arrived. On the atlas path only the slots the
        // placements leave unpainted: each fill is the slot its tile will
        // draw, on the same grid, so the tile replaces it at identical depth
        // and nothing coarser sits under the tiles to poke through their mesh.
        let placementState = frameContext.sharedState.tilePlacementState
        let placeholderSlots: [Tile]
        switch renderPath {
        case .vector:
            placeholderSlots = placementState.globeSurfaceSlots
        case .atlas:
            placeholderSlots = placementState.tileAtlasPlaceTilesContext.uncoveredSlots
        }
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
                                                slots: placeholderSlots)
        guard renderPath == .atlas else {
            return
        }
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
