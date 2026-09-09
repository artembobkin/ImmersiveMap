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
    private let separateRoadRenderingMinimumZoom: Int
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture

    init(tilePipeline: TilePipeline,
         groundOwnerState: MTLDepthStencilState,
         tileStencilTestState: MTLDepthStencilState,
         groundOutlineState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         separateRoadRenderingMinimumZoom: Int,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture) {
        self.tilePipeline = tilePipeline
        self.groundOwnerState = groundOwnerState
        self.tileStencilTestState = tileStencilTestState
        self.groundOutlineState = groundOutlineState
        self.depthDisabledState = depthDisabledState
        self.separateRoadRenderingMinimumZoom = separateRoadRenderingMinimumZoom
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
        // Distance LOD for the roads: they fade over a ring of camera
        // distances about the look-at point and are cut at its outer radius
        // (RoadDistanceLOD). The camera distance is measured the way the
        // ground coverage measures it, from the eye to the look-at point.
        let center = frameContext.visibleContent.center
        let lookAtWorld = FlatDistanceCoverage.worldPoint(ofTilePoint: SIMD2<Double>(center.tileX, center.tileY),
                                                          zoom: frameContext.visibleContent.tileZoomLevel,
                                                          flatRenderState: frameContext.resolvedPresentation.flatRenderState)
        let eye = frameContext.cameraEye
        let cameraDistance = simd_length(SIMD3<Double>(Double(eye.x), Double(eye.y), Double(eye.z)) - lookAtWorld)
        let roadFadeRadii = RoadDistanceLOD.fadeWorldDistances(cameraDistance: Float(cameraDistance),
                                                                unitsPerMeter: Float(unitsPerMeter),
                                                                startCameraDistances: debugControls.roadFadeStartCameraDistances,
                                                                endCameraDistances: debugControls.roadFadeEndCameraDistances,
                                                                minimumEndMeters: debugControls.roadFadeMinimumEndMeters)
        let roadFade = (centerWorld: SIMD2<Float>(Float(lookAtWorld.x), Float(lookAtWorld.y)),
                        start: roadFadeRadii.start,
                        end: roadFadeRadii.end)
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
                                  separateRoadRenderingMinimumZoom: separateRoadRenderingMinimumZoom,
                                  placeTilesContext: tilePlacementState.placeTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  groundShadowMask: groundShadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  groundOutlineState: groundOutlineState,
                                  isWireframeEnabled: isWireframeEnabled,
                                  markingCutoffWorldDistance: markingCutoff,
                                  roadFade: roadFade)
FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  drawableSizePx: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                               Float(frameContext.drawSize.height)),
                                  separateRoadRenderingMinimumZoom: separateRoadRenderingMinimumZoom,
                                  placeTilesContext: tilePlacementState.backdropPlaceTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  groundShadowMask: groundShadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  groundOutlineState: groundOutlineState,
                                  isWireframeEnabled: isWireframeEnabled,
                                  // The far band under the fog needs only the painted
                                  // ground: the backdrop's sub-pixel linework is skipped
                                  // (see the drawer).
                                  opaqueFillsOnly: true)
                encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
