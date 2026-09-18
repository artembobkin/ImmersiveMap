// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The flat ground: the main coverage's sources through the vector drawer
/// (`FlatMapSurfaceDrawer`), the rasterized rules' tiles as textured quads
/// (`TileRasterDrawer`) over pictures rendered ahead of the frame
/// (`TileRasterizer`, kept by `TileRasterStore`), and the horizon backdrop
/// last.
final class FlatMapSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "FlatMapSurface"

    private let tilePipeline: TilePipeline
    private let tileRasterPipeline: TileRasterPipeline
    private let groundOwnerState: MTLDepthStencilState
    private let tileStencilTestState: MTLDepthStencilState
    private let groundOutlineState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture
    private let rasterizer: TileRasterizer
    private let rasterStore = TileRasterStore()
    /// The rasterized sources of the frame, resolved in `prepareGPU` from
    /// the placements and the store, drawn in `encode`.
    private var rasterSources: [TileRasterDrawer.Source] = []
    /// The placements the vector drawer takes this frame: everything the
    /// raster sources do not cover.
    private var vectorPlaceTilesContext: PlaceTilesContext = .empty

    init(tilePipeline: TilePipeline,
         tileRasterPipeline: TileRasterPipeline,
         metalContext: RenderMetalContext,
         groundOwnerState: MTLDepthStencilState,
         tileStencilTestState: MTLDepthStencilState,
         groundOutlineState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture) {
        self.tilePipeline = tilePipeline
        self.tileRasterPipeline = tileRasterPipeline
        self.groundOwnerState = groundOwnerState
        self.tileStencilTestState = tileStencilTestState
        self.groundOutlineState = groundOutlineState
        self.depthDisabledState = depthDisabledState
        self.debugOverlayControls = debugOverlayControls
        self.groundShadowMaskTextureProvider = groundShadowMaskTextureProvider
        self.groundShadowMaskFallbackTexture = groundShadowMaskFallbackTexture
        self.rasterizer = TileRasterizer(metalContext: metalContext,
                                         tilePipeline: tilePipeline,
                                         groundOwnerState: groundOwnerState,
                                         tileStencilTestState: tileStencilTestState,
                                         groundOutlineState: groundOutlineState,
                                         groundShadowMaskFallbackTexture: groundShadowMaskFallbackTexture)
    }

    func update(frameContext _: FrameContext) {}

    /// Splits the main coverage into the vector placements and the raster
    /// sources, rendering the pictures the frame lacks. A rasterized target
    /// draws as a picture only when it is resident and placed in its own
    /// slot: a stand-in for a tile still loading stays vector, and so does
    /// a picture the device declined.
    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        rasterSources = []
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext
        vectorPlaceTilesContext = placements
        guard frameContext.renderSurfaceMode == .flat else {
            rasterStore.releaseStale(frameIndex: frameContext.frameIndex)
            return
        }
        let rasterizedTiles = frameContext.visibleContent.rasterizedTiles
        guard rasterizedTiles.isEmpty == false else {
            rasterStore.releaseStale(frameIndex: frameContext.frameIndex)
            return
        }
        let mapColor = frameContext.services.baseColors.map
        let clearColor = MTLClearColor(red: Double(mapColor.x), green: Double(mapColor.y),
                                       blue: Double(mapColor.z), alpha: Double(mapColor.w))
        var vectorPlacements: [PlaceTile] = []
        vectorPlacements.reserveCapacity(placements.tilePlacements.count)
        var seen = Set<TileRasterKey>()
        for placement in placements.tilePlacements {
            guard placement.inOwnSlot, let resolution = rasterizedTiles[placement.placeIn] else {
                vectorPlacements.append(placement)
                continue
            }
            let key = TileRasterKey(tile: placement.metalTile.tile, resolution: resolution)
            var texture = rasterStore.texture(for: key, frameIndex: frameContext.frameIndex)
            if texture == nil {
                texture = rasterizer.render(metalTile: placement.metalTile,
                                            resolution: resolution,
                                            pixelsPerPoint: Double(frameContext.pixelsPerPoint),
                                            clearColor: clearColor)
                if let texture {
                    rasterStore.insert(texture, for: key, frameIndex: frameContext.frameIndex)
                }
            }
            guard let texture else {
                vectorPlacements.append(placement)
                continue
            }
            // The world-wrap copies at the seam share one picture.
            if seen.insert(key).inserted || placement.placeIn.worldWrap != 0 {
                rasterSources.append(TileRasterDrawer.Source(tile: placement.metalTile.tile,
                                                             worldWrap: placement.placeIn.worldWrap,
                                                             texture: texture))
            }
        }
        vectorPlaceTilesContext = PlaceTilesContext(tilePlacements: vectorPlacements)
        rasterStore.releaseStale(frameIndex: frameContext.frameIndex)
    }

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
        let drawableSizePx = SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height))
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
                                  drawableSizePx: drawableSizePx,
                                  placeTilesContext: vectorPlaceTilesContext,
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
        // The rasterized sources: their pictures over their extents, the
        // stencil deciding against the vector sources as between any two
        // sources. Between the main coverage and the backdrop, since the
        // stencil, not the order, settles ownership among them all.
        TileRasterDrawer.draw(renderEncoder: encoder,
                              cameraUniform: frameContext.cameraUniform,
                              sources: rasterSources,
                              flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                              groundShadowMask: groundShadowMask,
                              pipeline: tileRasterPipeline,
                              groundOwnerState: groundOwnerState)
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cameraZoom: frameContext.zoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  drawableSizePx: drawableSizePx,
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

    func handleMemoryWarning() {
        rasterStore.removeAll()
        rasterizer.releaseScratch()
    }

    func evict() {
        rasterStore.removeAll()
        rasterizer.releaseScratch()
    }
}
