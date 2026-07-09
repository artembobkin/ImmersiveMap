// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class TerrainRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "Terrain"

    private let terrainPipeline: TerrainPipeline
    private let terrainTileStore: TerrainTileStore
    private let terrainDepthState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState

    init(terrainPipeline: TerrainPipeline,
         terrainTileStore: TerrainTileStore,
         terrainDepthState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState) {
        self.terrainPipeline = terrainPipeline
        self.terrainTileStore = terrainTileStore
        self.terrainDepthState = terrainDepthState
        self.debugOverlayControls = debugOverlayControls
    }

    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.terrainEnabled = RenderTerrainAvailabilityPolicy.shouldRender(settings: settings,
                                                                              controls: debugOverlayControls.snapshot())
    }

    func update(frameContext: FrameContext) {
        guard RenderTerrainAvailabilityPolicy.shouldRender(settings: frameContext.services.settings,
                                                           controls: debugOverlayControls.snapshot()) else {
            return
        }

        terrainTileStore.requestVisibleTiles(frameContext.visibleContent.visibleTiles,
                                             terrain: frameContext.services.settings.terrain,
                                             renderSurfaceMode: frameContext.renderSurfaceMode,
                                             globeRadius: frameContext.globeRenderUniform.radius)
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry: RenderResourceRegistry) {
        resourceRegistry.setPipeline(terrainPipeline.pipelineState, named: .terrainPipeline)
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .terrain,
              RenderTerrainAvailabilityPolicy.shouldRender(settings: frameContext.services.settings,
                                                           controls: debugOverlayControls.snapshot()) else {
            return
        }

        encoder.setDepthStencilState(terrainDepthState)
        TerrainDrawer.draw(renderEncoder: encoder,
                           cameraUniform: frameContext.cameraUniform,
                           globe: frameContext.globeRenderUniform,
                           terrain: frameContext.services.settings.terrain,
                           visibleTiles: frameContext.visibleContent.visibleTiles,
                           renderSurfaceMode: frameContext.renderSurfaceMode,
                           flatRenderState: frameContext.flatRenderState,
                           terrainPipeline: terrainPipeline,
                           terrainTileStore: terrainTileStore,
                           isWireframeEnabled: debugOverlayControls.snapshot().wireframeEnabled)
    }

    func handleMemoryWarning() {
        terrainTileStore.handleMemoryWarning()
    }

    func evict() {
        terrainTileStore.evict()
    }
}
