// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The flat ground: the main coverage's sources through the vector drawer
/// (`FlatMapSurfaceDrawer`), every tile as geometry at every distance.
/// Nothing is drawn under them: beyond the last rule the haze paints the
/// horizon.
final class FlatMapSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "FlatMapSurface"

    private let tilePipeline: TilePipeline
    private let groundOwnerState: MTLDepthStencilState
    private let tileStencilTestState: MTLDepthStencilState
    private let roadSheetStates: RoadSheetStates
    private let depthDisabledState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture

    init(tilePipeline: TilePipeline,
         groundOwnerState: MTLDepthStencilState,
         tileStencilTestState: MTLDepthStencilState,
         roadSheetStates: RoadSheetStates,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture) {
        self.tilePipeline = tilePipeline
        self.groundOwnerState = groundOwnerState
        self.tileStencilTestState = tileStencilTestState
        self.roadSheetStates = roadSheetStates
        self.depthDisabledState = depthDisabledState
        self.debugOverlayControls = debugOverlayControls
        self.groundShadowMaskTextureProvider = groundShadowMaskTextureProvider
        self.groundShadowMaskFallbackTexture = groundShadowMaskFallbackTexture
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .flatMapSurface,
              frameContext.renderSurfaceMode == .flat else {
            return
        }
        let placeTilesContext = frameContext.sharedState.tilePlacementState.placeTilesContext
        guard placeTilesContext.tilePlacements.isEmpty == false else { return }

        let isWireframeEnabled = debugOverlayControls.snapshot().wireframeEnabled
        let groundShadowMask = GroundShadowMaskBinding.resolve(frameContext: frameContext,
                                                               maskTexture: groundShadowMaskTextureProvider(),
                                                               fallbackTexture: groundShadowMaskFallbackTexture)
        let drawableSizePx = SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height))
        // The drawer sets its own depth-stencil states per group: the
        // ground owns the tile-priority stencil (depth tested against the
        // buildings, never written), the road buckets only test it. The
        // layered ground writes rank depth, so everything draws
        // finest-first (the sphere's rule) and the stencil settles which
        // source owns a pixel.
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  drawableSizePx: drawableSizePx,
                                  placeTilesContext: placeTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  groundShadowMask: groundShadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  roadSheetStates: roadSheetStates,
                                  isWireframeEnabled: isWireframeEnabled,
                                  // The target zoom's tiles keep the rank depth in
                                  // the vertex z, every coarser band writes it
                                  // exactly (FlatMapSurfaceDrawer.usesExactRankDepth).
                                  exactRankDepthBelowZoom: frameContext.visibleContent.tileZoomLevel,
                                  linelessTiles: frameContext.visibleContent.linelessTiles)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
