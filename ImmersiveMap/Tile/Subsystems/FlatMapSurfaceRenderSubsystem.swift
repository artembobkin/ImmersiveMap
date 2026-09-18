// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

final class FlatMapSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "FlatMapSurface"

    private let tilePipeline: TilePipeline
    private let groundOwnerState: MTLDepthStencilState
    private let tileStencilTestState: MTLDepthStencilState
    private let groundOutlineState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture

    init(tilePipeline: TilePipeline,
         groundOwnerState: MTLDepthStencilState,
         tileStencilTestState: MTLDepthStencilState,
         groundOutlineState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture) {
        self.tilePipeline = tilePipeline
        self.groundOwnerState = groundOwnerState
        self.tileStencilTestState = tileStencilTestState
        self.groundOutlineState = groundOutlineState
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

        let tilePlacementState = frameContext.sharedState.tilePlacementState
        let debugControls = debugOverlayControls.snapshot()
        let isWireframeEnabled = debugControls.wireframeEnabled
        let groundShadowMask = GroundShadowMaskBinding.resolve(frameContext: frameContext,
                                                               maskTexture: groundShadowMaskTextureProvider(),
                                                               fallbackTexture: groundShadowMaskFallbackTexture)
        // Distance LOD for road paint: beyond this camera distance the
        // world-locked markings are sub-pixel, and a tile entirely past it
        // skips its marking draws (RoadMarkingDistanceLOD).
        let latitudeRadians = ImmersiveMapProjection.latitude(
            fromNormalizedWorldY: frameContext.mapCameraState.centerWorldMercator.y)
        let unitsPerMeter = ImmersiveMapProjection.worldUnitsPerMeter(
            latitudeRadians: latitudeRadians,
            renderMapSize: frameContext.resolvedPresentation.flatRenderState.renderMapSize)
        let markingCutoff = RoadMarkingDistanceLOD.cutoffWorldDistance(
            drawableHeightPx: Float(frameContext.drawSize.height),
            unitsPerMeter: Float(unitsPerMeter))
        // The drawer sets its own depth-stencil states per group: the
        // ground owns the tile-priority stencil (depth tested against the
        // buildings, never written), the road buckets only test it.
        // The MAIN coverage draws first and the coarse horizon backdrop
        // last: the layered ground writes rank depth, so everything must
        // draw finest-first (the sphere's rule), and the stencil carves the
        // backdrop out of every pixel the main coverage owns instead of the
        // old painter's order; beyond the coverage's edge the backdrop
        // still paints all the way to the horizon. The backdrop binds the
        // same shadow mask: it lies outside the fitted shadow map, so the
        // mask is lit there.
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  drawableSizePx: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                               Float(frameContext.drawSize.height)),
                                  placeTilesContext: tilePlacementState.placeTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  groundShadowMask: groundShadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  groundOutlineState: groundOutlineState,
                                  isWireframeEnabled: isWireframeEnabled,
                                  // The target zoom's tiles keep the rank depth in
                                  // the vertex z, every coarser band writes it
                                  // exactly (FlatMapSurfaceDrawer.usesExactRankDepth).
                                  exactRankDepthBelowZoom: frameContext.visibleContent.tileZoomLevel,
                                  markingCutoffWorldDistance: markingCutoff)
FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  drawableSizePx: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                               Float(frameContext.drawSize.height)),
                                  placeTilesContext: tilePlacementState.backdropPlaceTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  groundShadowMask: groundShadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  groundOutlineState: groundOutlineState,
                                  isWireframeEnabled: isWireframeEnabled,
                                  // The backdrop's z0 cells are the largest triangles
                                  // of the frame: every one of its sources writes the
                                  // rank depth exactly.
                                  exactRankDepthBelowZoom: .max,
                                  // The far band under the fog needs only the painted
                                  // ground: the backdrop's sub-pixel linework is skipped
                                  // (see the drawer).
                                  opaqueFillsOnly: true)
                encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
