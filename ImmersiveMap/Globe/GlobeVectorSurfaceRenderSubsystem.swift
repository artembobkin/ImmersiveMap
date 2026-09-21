// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The globe's ground: the placements' ground geometry projected onto the
/// sphere in the vertex stage (`GlobeVectorSurfaceDrawer`) and, past the
/// raster zone's start (`RasterZone`), the rasterizable rules' tiles as
/// pictures laid over the sphere (`TileSphereRasterDrawer`), the same
/// textures the plane draws (`TileRasterPictures`). A tile's extent is its
/// full square: which source owns a pixel is the tile-priority stencil's
/// answer, marked by whatever draws a tile's opaque ground first, and the
/// far hemisphere goes to back-face culling.
///
/// The ground draws in three steps, the plane's scheme
/// (`FlatMapSurfaceRenderSubsystem`) fitted to a sphere that has no
/// ownership prepass. First the geometry under the pictures, every source
/// finest first in one call: the tiles nearer than the zone whole, and the
/// pictured families of the tiles the zone's edge crosses. Every vector
/// source's opaque pass has run by then, so the stencil already keeps a
/// coarser source's overflow out of a finer tile's ground. Then the
/// pictures, each pixel's share by its distance from the camera. Last the
/// geometry over them: the ground lines of pictured tiles, when the zone
/// keeps lines as geometry. A picture on the sphere holds every fill.
final class GlobeVectorSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeVectorSurface"

    private let pipeline: TilePipeline
    private let depthDisabledState: MTLDepthStencilState
    private let opaqueDepthState: MTLDepthStencilState
    private let translucentDepthState: MTLDepthStencilState
    private let rasterPipeline: TileSphereRasterPipeline
    private let pictures: TileRasterPictures
    private let debugOverlayControls: DebugOverlayControlState
    /// The frame's pictured sources, resolved in `prepareGPU`.
    private var rasterSources: [TileSphereRasterDrawer.Source] = []
    /// The ground families each pictured tile draws under the pictures and
    /// over them. A tile not named draws whole under them.
    private var underPicturesGroups: [Tile: GroundLayerGroups] = [:]
    private var overPicturesGroups: [Tile: GroundLayerGroups] = [:]
    private var overPicturesContext: PlaceTilesContext = .empty
    private var zoneSpan = RasterZone.Span(start: 0, end: 0)

    init(pipeline: TilePipeline,
         depthDisabledState: MTLDepthStencilState,
         opaqueDepthState: MTLDepthStencilState,
         translucentDepthState: MTLDepthStencilState,
         rasterPipeline: TileSphereRasterPipeline,
         pictures: TileRasterPictures,
         debugOverlayControls: DebugOverlayControlState) {
        self.pipeline = pipeline
        self.depthDisabledState = depthDisabledState
        self.opaqueDepthState = opaqueDepthState
        self.translucentDepthState = translucentDepthState
        self.rasterPipeline = rasterPipeline
        self.pictures = pictures
        self.debugOverlayControls = debugOverlayControls
    }

    func update(frameContext _: FrameContext) {}

    /// How a tile of the sphere draws against the zone, by the nearest and
    /// the farthest point of its bounding sphere from the eye. Through the
    /// unfurl the bound does not hold the surface, so every tile is drawn
    /// both ways and the pixel's own distance decides.
    static func tileDraw(span: RasterZone.Span,
                         eye: SIMD3<Float>,
                         boundCenter: SIMD3<Float>,
                         boundRadius: Float,
                         isUnfurling: Bool) -> RasterZone.TileDraw {
        guard isUnfurling == false else { return .blended }
        let centerDistance = simd_length(boundCenter - eye)
        if centerDistance + boundRadius <= span.start {
            return .vector
        }
        return max(centerDistance - boundRadius, 0) >= span.end ? .picture : .blended
    }

    /// The families a picture on the sphere holds: every fill, since a
    /// fill drawn over a depth-writing picture would fail the rank test,
    /// and the lines by the zone's switch and the rule's.
    static func pictureGroups(zone: RasterZone, drawsLines: Bool) -> GroundLayerGroups {
        zone.pictureGroups(drawsLines: drawsLines).union([.landFills, .buildingFootprints])
    }

    /// Sorts the frame's rasterizable tiles against the zone, rendering
    /// the pictures the frame lacks. A stand-in for a tile still loading
    /// stays vector, and so does a picture the device declined.
    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        rasterSources = []
        underPicturesGroups = [:]
        overPicturesGroups = [:]
        overPicturesContext = .empty
        // The plane's ground looks after the pictures while it is live.
        guard frameContext.renderSurfaceMode == .spherical else { return }
        defer { pictures.releaseStale(frameIndex: frameContext.frameIndex) }
        let controls = debugOverlayControls.snapshot(forTargetZoom: frameContext.visibleContent.tileZoomLevel)
        let zone = controls.rasterZone
        let rasterizedTiles = frameContext.visibleContent.rasterizedTiles
        guard zone.isEnabled, rasterizedTiles.isEmpty == false else { return }

        let eye = frameContext.cameraUniform.eye
        let globe = frameContext.globeRenderUniform
        zoneSpan = zone.span(eye: eye)
        let visibility = GlobeVisibilityModel.makeInputs(globe: globe, cameraEye: eye)
        let isUnfurling = globe.transition > 0
        let request = TileRasterPictures.FrameRequest(frameContext: frameContext, controls: controls)
        var overPlacements: [PlaceTile] = []
        for placement in frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements {
            let tile = placement.metalTile.tile
            guard placement.inOwnSlot,
                  overPicturesGroups[tile] == nil,
                  let resolution = rasterizedTiles[placement.placeIn] else { continue }
            let bound = GlobeVisibilityModel.tileBound(tile: tile, inputs: visibility)
            let tileDraw = Self.tileDraw(span: zoneSpan, eye: eye, boundCenter: bound.center,
                                         boundRadius: bound.radius, isUnfurling: isUnfurling)
            guard tileDraw != .vector else { continue }
            let drawsLines = frameContext.visibleContent.linelessTiles.contains(placement.placeIn) == false
            let groups = Self.pictureGroups(zone: zone, drawsLines: drawsLines)
            guard let texture = pictures.picture(of: placement.metalTile, resolution: resolution,
                                                 groups: groups, request: request) else { continue }
            let isBlended = tileDraw == .blended
            underPicturesGroups[tile] = isBlended ? groups : []
            overPicturesGroups[tile] = GroundLayerGroups.all.subtracting(groups)
            overPlacements.append(placement)
            rasterSources.append(TileSphereRasterDrawer.Source(tile: tile, texture: texture, isBlended: isBlended))
        }
        overPicturesContext = PlaceTilesContext(tilePlacements: overPlacements)
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .globeVectorSurface,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        let globe = frameContext.globeRenderUniform
        let pureSphere = GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                            transition: globe.transition)
        let globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: frameContext.cameraUniform.matrix)
        let isWireframeEnabled = debugOverlayControls.snapshot().wireframeEnabled
        func drawGround(_ placeTilesContext: PlaceTilesContext, sourceGroups: [Tile: GroundLayerGroups]) {
            guard placeTilesContext.tilePlacements.isEmpty == false else { return }
            encoder.setDepthStencilState(depthDisabledState)
            GlobeVectorSurfaceDrawer.draw(renderEncoder: encoder,
                                          cameraUniform: frameContext.cameraUniform,
                                          globe: globe,
                                          cameraZoom: frameContext.zoom,
                                          pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                          drawableHeightPx: Float(frameContext.drawSize.height),
                                          renderMapSize: frameContext.resolvedPresentation.renderNormalizationState.flatRenderMapSize,
                                          placeTilesContext: placeTilesContext,
                                          pipeline: pipeline,
                                          opaqueDepthState: opaqueDepthState,
                                          translucentDepthState: translucentDepthState,
                                          depthDisabledState: depthDisabledState,
                                          isWireframeEnabled: isWireframeEnabled,
                                          pureSphere: pureSphere,
                                          globeFrame: globeFrame,
                                          linelessTiles: frameContext.visibleContent.linelessTiles,
                                          sourceGroups: sourceGroups)
        }
        // Under the pictures: every source, the pictured tiles by the
        // families their pictures hold.
        drawGround(frameContext.sharedState.tilePlacementState.placeTilesContext, sourceGroups: underPicturesGroups)
        TileSphereRasterDrawer.draw(renderEncoder: encoder,
                                    cameraUniform: frameContext.cameraUniform,
                                    globe: globe,
                                    globeFrame: globeFrame,
                                    sources: rasterSources,
                                    pipeline: rasterPipeline,
                                    zoneSpan: zoneSpan,
                                    morph: pureSphere == false,
                                    ownerState: opaqueDepthState,
                                    tileStencilTestState: translucentDepthState,
                                    depthDisabledState: depthDisabledState)
        // Over the pictures: what the pictured tiles keep as geometry.
        if overPicturesGroups.values.contains(where: { $0.isEmpty == false }) {
            drawGround(overPicturesContext, sourceGroups: overPicturesGroups)
        }
    }

    func handleMemoryWarning() {
        pictures.removeAll()
    }

    func evict() {
        pictures.removeAll()
    }
}
