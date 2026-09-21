// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The flat ground: the main coverage's sources through the vector drawer
/// (`FlatMapSurfaceDrawer`) and, past the raster zone's start
/// (`RasterZone`), the rasterizable rules' tiles as textured quads
/// (`TileRasterDrawer`) over pictures rendered ahead of the frame
/// (`TileRasterizer`, kept by `TileRasterStore`). Nothing is drawn under
/// them: beyond the last rule the haze paints the horizon.
///
/// The ground draws in three steps. Under the pictures, the pictured
/// families of every tile the zone's edge crosses, as geometry. Then the
/// pictures, each blended in by the distance from the camera, pixel by
/// pixel. Over them, everything that is geometry at every distance: the
/// tiles nearer than the zone whole, the families the pictures leave out,
/// and the roads of every tile.
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
    /// The pictures, shared with the sphere's ground (`TileRasterPictures`).
    private let pictures: TileRasterPictures
    /// The rasterized sources of the frame, resolved in `prepareGPU` from
    /// the placements and the store, drawn in `encode`.
    private var rasterSources: [TileRasterDrawer.Source] = []
    /// The placements whose pictured families draw as geometry under
    /// their pictures: the tiles the zone's edge crosses.
    private var underPicturesContext: PlaceTilesContext = .empty
    /// The ground families each pictured tile draws in the two vector
    /// steps: what its picture holds under it, the rest over it.
    private var underPicturesGroups: [FlatGroundSourceKey: GroundLayerGroups] = [:]
    private var overPicturesGroups: [FlatGroundSourceKey: GroundLayerGroups] = [:]
    private var zoneSpan = RasterZone.Span(start: 0, end: 0)

    init(tilePipeline: TilePipeline,
         tileRasterPipeline: TileRasterPipeline,
         pictures: TileRasterPictures,
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
        self.pictures = pictures
    }

    func update(frameContext _: FrameContext) {}

    /// Sorts the main coverage's tiles against the raster zone, rendering
    /// the pictures the frame lacks. A tile takes a picture only when its
    /// rule is rasterizable, it reaches into the zone, and it is resident
    /// and placed in its own slot: a stand-in for a tile still loading
    /// stays vector, and so does a picture the device declined.
    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        rasterSources = []
        underPicturesContext = .empty
        underPicturesGroups = [:]
        overPicturesGroups = [:]
        // The sphere's ground looks after the pictures while it is live.
        guard frameContext.renderSurfaceMode == .flat else { return }
        defer { pictures.releaseStale(frameIndex: frameContext.frameIndex) }
        let controls = debugOverlayControls.snapshot(forTargetZoom: frameContext.visibleContent.tileZoomLevel)
        let zone = controls.rasterZone
        let rasterizedTiles = frameContext.visibleContent.rasterizedTiles
        guard zone.isEnabled, rasterizedTiles.isEmpty == false else {
            return
        }
        let eye = frameContext.cameraUniform.eye
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        zoneSpan = zone.span(eye: eye)
        let request = TileRasterPictures.FrameRequest(frameContext: frameContext, controls: controls)
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext
        var underPlacements: [PlaceTile] = []
        var seen = Set<TileRasterKey>()
        for placement in placements.tilePlacements {
            guard placement.inOwnSlot, let resolution = rasterizedTiles[placement.placeIn] else { continue }
            let tile = placement.metalTile.tile
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             worldWrap: placement.placeIn.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let tileDraw = RasterZone.tileDraw(span: zoneSpan, eye: eye, tileOriginAndSize: originAndSize)
            guard tileDraw != .vector else { continue }
            let drawsLines = frameContext.visibleContent.linelessTiles.contains(placement.placeIn) == false
            let groups = zone.pictureGroups(drawsLines: drawsLines)
            guard let texture = pictures.picture(of: placement.metalTile, resolution: resolution,
                                                 groups: groups, request: request) else { continue }
            let key = pictures.key(tile: tile, resolution: resolution, groups: groups, request: request)
            // A tile the world wraps onto the screen twice is judged at
            // each copy, like the vector drawer's sources.
            let sourceKey = FlatGroundSourceKey(tile: tile, worldWrap: placement.placeIn.worldWrap)
            let isBlended = tileDraw == .blended
            if isBlended {
                underPlacements.append(placement)
                underPicturesGroups[sourceKey] = groups
            }
            overPicturesGroups[sourceKey] = GroundLayerGroups.all.subtracting(groups)
            // The world-wrap copies at the seam share one picture.
            if seen.insert(key).inserted || placement.placeIn.worldWrap != 0 {
                rasterSources.append(TileRasterDrawer.Source(tile: tile,
                                                             worldWrap: placement.placeIn.worldWrap,
                                                             texture: texture,
                                                             isBlended: isBlended))
            }
        }
        underPicturesContext = PlaceTilesContext(tilePlacements: underPlacements)
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .flatMapSurface,
              frameContext.renderSurfaceMode == .flat else {
            return
        }

        let debugControls = debugOverlayControls.snapshot(forTargetZoom: frameContext.visibleContent.tileZoomLevel)
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
        // buildings, never written), the road buckets only test it. The
        // layered ground writes rank depth, so everything draws
        // finest-first (the sphere's rule) and the stencil settles which
        // source owns a pixel.
        let exactRankDepthBelowZoom = frameContext.visibleContent.tileZoomLevel
        func drawGround(_ placeTilesContext: PlaceTilesContext,
                        sourceGroups: [FlatGroundSourceKey: GroundLayerGroups],
                        drawsRoads: Bool) {
            guard placeTilesContext.tilePlacements.isEmpty == false else { return }
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
                                      groundOutlineState: groundOutlineState,
                                      isWireframeEnabled: isWireframeEnabled,
                                      // The target zoom's tiles keep the rank depth in
                                      // the vertex z, every coarser band writes it
                                      // exactly (FlatMapSurfaceDrawer.usesExactRankDepth).
                                      exactRankDepthBelowZoom: exactRankDepthBelowZoom,
                                      markingCutoffWorldDistance: markingCutoff,
                                      linelessTiles: frameContext.visibleContent.linelessTiles,
                                      sourceGroups: sourceGroups,
                                      drawsRoads: drawsRoads,
                                      roadThinnessFade: debugControls.roadThinnessFade,
                                      footprintGoneAreaPx: debugControls.buildingGoneAreaPixels,
                                      footprintOpaqueAreaPx: debugControls.buildingOpaqueAreaPixels)
        }
        // Under the pictures: the pictured families of the tiles the
        // zone's edge crosses, which show where a picture has not faded in.
        drawGround(underPicturesContext, sourceGroups: underPicturesGroups, drawsRoads: false)
        // The pictures, each pixel's share by its distance from the
        // camera, the stencil deciding against the vector sources as
        // between any two sources.
        TileRasterDrawer.draw(renderEncoder: encoder,
                              cameraUniform: frameContext.cameraUniform,
                              sources: rasterSources,
                              flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                              groundShadowMask: groundShadowMask,
                              pipeline: tileRasterPipeline,
                              zoneSpan: zoneSpan,
                              groundOwnerState: groundOwnerState,
                              tileStencilTestState: tileStencilTestState)
        // Over the pictures: every tile's geometry that is geometry at
        // every distance, the roads among it.
        drawGround(frameContext.sharedState.tilePlacementState.placeTilesContext,
                   sourceGroups: overPicturesGroups,
                   drawsRoads: true)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {
        pictures.removeAll()
    }

    func evict() {
        pictures.removeAll()
    }
}
