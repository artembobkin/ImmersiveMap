// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Draws the tile grid on the ground of whichever surface the frame shows,
/// in a render layer of its own in the overlay pass
/// (`RenderLayer.tileGrid`): over the whole world, the buildings and the
/// map's names included, so nothing the map draws covers a border or a
/// tile's numbers, and under the pins. A frame with no
/// controller attached, or whose tiles are too small on screen, leaves the
/// render layer out.
///
/// A frame works out its grid anew from the camera, the settings and the
/// controller, and keeps nothing between frames but the texts it laid out
/// (`TileGridLabels`): the zoom whose tiles show (`TileGridZoom`), those
/// tiles in view, the nearest first (`TileGridCoverage`), the selected
/// among them, and the selected tiles of every other zoom in view, drawn
/// as their fill alone. The grid lies on the plane and does not rise with
/// the ground relief, as the layers of the app's data do not. It is unlit
/// and takes no fog, so it reads the same by day and on the night side.
final class TileGridRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "TileGrid"

    private let source: TileGridRenderSource
    private let pipeline: TileGridPipeline
    private let textRenderer: TextRenderer
    private let depthDisabledState: MTLDepthStencilState
    private let labels: TileGridLabels
    private let tileBuffers: FrameSlottedDynamicMetalBuffer<TileGridTileGPU>
    private let glyphBuffers: FrameSlottedDynamicMetalBuffer<TileGridGlyphGPU>

    /// The frame's tiles: the grid's own first, then the selected tiles of
    /// other zooms.
    private var tiles: [TileGridTileGPU] = []
    private var gridTileCount = 0
    /// The coarsest zoom among the tiles of each of the two groups, which
    /// decides how finely their patches are divided.
    private var gridZoom = 0
    private var otherCoarsestZoom = 0
    private var glyphs: [TileGridGlyphGPU] = []
    private var frameUniform: TileGridFrameUniform?

    init(source: TileGridRenderSource,
         pipeline: TileGridPipeline,
         textRenderer: TextRenderer,
         metalDevice: MTLDevice,
         depthDisabledState: MTLDepthStencilState) {
        self.source = source
        self.pipeline = pipeline
        self.textRenderer = textRenderer
        self.depthDisabledState = depthDisabledState
        labels = TileGridLabels { [textRenderer] text in
            textRenderer.collectLabelVertices(for: text, labelIndex: 0, scale: 1)
        }
        tileBuffers = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                     slotsCount: InFlightFramePool.inFlightFramesCount,
                                                     options: [.storageModeShared])
        glyphBuffers = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                      slotsCount: InFlightFramePool.inFlightFramesCount,
                                                      options: [.storageModeShared])
    }

    func update(frameContext: FrameContext) {
        tiles.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        gridTileCount = 0
        frameUniform = nil
        // No controller, no grid: nothing is drawn and nothing is told to
        // the tap, which then never asks.
        guard let content = source.tileGridContent else { return }
        let settings = frameContext.services.settings.tileGrid
        let resolution = resolution(frameContext: frameContext, settings: settings)
        publishPickData(resolution: resolution, settings: settings, frameContext: frameContext)
        guard let resolution else { return }
        let view = TileGridView(frameContext: frameContext)

        let visible = view.nearestTiles(zoom: resolution.zoom, limit: settings.maximumDrawnTiles)
        gridZoom = resolution.zoom
        gridTileCount = visible.count
        for tile in visible {
            let isSelected = content.selectedTiles.contains(ImmersiveMapTileID(tile.tile))
            tiles.append(view.gpuTile(tile, flags: isSelected ? TileGridTileGPU.selectedFlag : 0))
        }

        // The selected tiles of the other zooms, where they show.
        otherCoarsestZoom = ImmersiveMapTileID.maximumZoom
        var otherCount = 0
        for selected in content.selectedTiles where selected.zoom != resolution.zoom {
            guard otherCount < settings.maximumDrawnTiles else { break }
            for copy in view.copies(showing: selected.tile) {
                tiles.append(view.gpuTile(copy, flags: TileGridTileGPU.selectedFlag | TileGridTileGPU.fillOnlyFlag))
                otherCount += 1
                otherCoarsestZoom = min(otherCoarsestZoom, selected.zoom)
            }
        }
        guard tiles.isEmpty == false else { return }

        let pixelsPerPoint = Float(frameContext.pixelsPerPoint)
        if resolution.drawsLabels {
            glyphs = labels.glyphs(for: visible,
                                   settings: settings,
                                   content: content,
                                   minimumTilePx: settings.labelMinimumTileScreenPoints * pixelsPerPoint)
        }
        let atlas = textRenderer.atlasData.atlas
        frameUniform = TileGridFrameUniform(lineColor: settings.lineColor,
                                            selectedFillColor: settings.selectedFillColor,
                                            labelColor: settings.labelColor,
                                            labelHaloColor: settings.labelHaloColor,
                                            halfLineWidthPx: settings.lineWidthPoints * pixelsPerPoint * 0.5,
                                            minimumTilePx: settings.minimumTileScreenPoints * pixelsPerPoint,
                                            depth: TileGridDepth.depth,
                                            atlasDistanceRange: Float(atlas.distanceRange),
                                            atlasEmTexels: Float(atlas.size),
                                            haloWidthPx: settings.labelHaloWidthPoints * pixelsPerPoint,
                                            haloPass: 0)
    }

    /// The zoom the frame's grid shows, nil when it shows none.
    private func resolution(frameContext: FrameContext,
                            settings: ImmersiveMapSettings.TileGridSettings) -> TileGridZoom.Resolution? {
        // The render world is normalized to the camera's integer zoom, so
        // the map's size over that zoom's tile count is one such tile.
        let normalization = frameContext.resolvedPresentation.renderNormalizationState
        let viewportHeightPoints = Double(frameContext.drawSize.height) / max(Double(frameContext.pixelsPerPoint), 1)
        let base = TileGridZoom.baseTileScreenPoints(viewportHeightPoints: viewportHeightPoints,
                                                     tileWorldSize: normalization.flatRenderMapSize / normalization.zoomScale)
        // The camera's own zoom, not the one the map is planned by: the
        // threshold is about what is on screen.
        return TileGridZoom.resolve(cameraZoom: frameContext.zoom, baseTileScreenPoints: base, settings: settings)
    }

    /// What a tap can land on: the tiles of the zoom this frame shows, by
    /// the projection it draws them with. A snapshot without a projection
    /// too: a grid that stops being shown stops being tappable.
    private func publishPickData(resolution: TileGridZoom.Resolution?,
                                 settings: ImmersiveMapSettings.TileGridSettings,
                                 frameContext: FrameContext) {
        let takesTaps = resolution != nil && settings.isTapSelectionEnabled
        let projection = takesTaps ? GeoScreenProjectionMath.FrameConstants(
            drawSize: frameContext.drawSize,
            cameraUniform: frameContext.cameraUniform,
            resolvedPresentation: frameContext.resolvedPresentation) : nil
        frameContext.sharedState.selectionPickData.append(TileGridSelectionSnapshot(
            frameIndex: frameContext.frameIndex,
            drawSize: frameContext.drawSize,
            projection: projection,
            zoom: resolution?.zoom ?? 0,
            gesture: settings.selectionGesture,
            mode: settings.selectionMode,
            selectionLimit: settings.selectionLimit,
            selectableBounds: settings.selectableBounds))
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        guard tiles.isEmpty == false else { return }
        let slot = frameContext.frameSlotIndex
        Self.upload(tiles, to: tileBuffers.ensureCapacity(slot: slot, count: tiles.count))
        if glyphs.isEmpty == false {
            Self.upload(glyphs, to: glyphBuffers.ensureCapacity(slot: slot, count: glyphs.count))
        }
    }

    private static func upload<Element>(_ values: [Element], to buffer: MTLBuffer) {
        values.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.tileGridEnabled = builder.tileGridEnabled || tiles.isEmpty == false
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .tileGrid, tiles.isEmpty == false, var frame = frameUniform else { return }
        let surface: TileGridPipeline.Surface
        switch frameContext.renderSurfaceMode {
        case .flat:
            surface = .flat
        case .spherical:
            let globe = frameContext.globeRenderUniform
            surface = GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                          transition: globe.transition) ? .sphere : .morph
        }

        encoder.pushDebugGroup("tile grid")
        let slot = frameContext.frameSlotIndex
        let tileBuffer = tileBuffers.buffer(for: slot)
        let states = pipeline.states(for: surface)
        var cameraUniform = frameContext.cameraUniform
        var globe = frameContext.globeRenderUniform
        var globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: cameraUniform.matrix)
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        encoder.setVertexBytes(&frame, length: MemoryLayout<TileGridFrameUniform>.stride, index: 2)
        encoder.setVertexBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 8)
        encoder.setVertexBytes(&globeFrame, length: MemoryLayout<GlobeFrameConstantsUniform>.stride, index: 10)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<TileGridFrameUniform>.stride, index: 0)
        encoder.setDepthStencilState(pipeline.depthState)
        // A patch that crosses the limb is cut by its clip distance, and a
        // patch has no back to cull.
        encoder.setCullMode(.none)

        // The patches: the fills of the other zooms' selected tiles under
        // the grid's own borders.
        encoder.setRenderPipelineState(states.patch)
        encoder.setVertexBuffer(tileBuffer, offset: 0, index: 0)
        let groups = [(start: gridTileCount, count: tiles.count - gridTileCount, zoom: otherCoarsestZoom),
                      (start: 0, count: gridTileCount, zoom: gridZoom)]
        for group in groups where group.count > 0 {
            let lattice = pipeline.latticeIndices(subdivision: TileGridPipeline.subdivision(zoom: group.zoom,
                                                                                           surface: surface))
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: lattice.count,
                                          indexType: .uint16,
                                          indexBuffer: lattice.buffer,
                                          indexBufferOffset: 0,
                                          instanceCount: group.count,
                                          baseVertex: 0,
                                          baseInstance: group.start)
        }

        // The texts: every halo, then every fill over them.
        if glyphs.isEmpty == false {
            encoder.setRenderPipelineState(states.glyph)
            encoder.setVertexBuffer(glyphBuffers.buffer(for: slot), offset: 0, index: 0)
            encoder.setVertexBuffer(tileBuffer, offset: 0, index: 3)
            encoder.setFragmentTexture(textRenderer.texture, index: 0)
            for haloPass in [true, false] where haloPass == false || frame.haloWidthPx > 0 {
                frame.haloPass = haloPass ? 1 : 0
                encoder.setFragmentBytes(&frame, length: MemoryLayout<TileGridFrameUniform>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: glyphs.count)
            }
        }

        encoder.setDepthStencilState(depthDisabledState)
        encoder.popDebugGroup()
    }

    func handleMemoryWarning() {}

    func evict() {}
}

/// The frame's view of the ground, as the grid needs it: which tiles show
/// and where a tile is drawn. What the tests of a surface read is worked
/// out once, for every tile the frame asks about.
private struct TileGridView {
    private enum Surface {
        /// The frustum's footprint on the plane, nil when it has none.
        case flat(CoveragePolygon?)
        case globe(GlobeVisibilityInputs, Frustum)
    }

    private let surface: Surface
    private let centre: SIMD2<Double>
    private let flatRenderState: FlatRenderState

    init(frameContext: FrameContext) {
        let cameraMatrix = frameContext.cameraMatrices.projectionView
        switch frameContext.renderSurfaceMode {
        case .flat:
            surface = .flat(CoveragePolygonBuilder.make(cameraMatrix: cameraMatrix))
        case .spherical:
            surface = .globe(GlobeVisibilityModel.makeInputs(globe: frameContext.globeRenderUniform,
                                                             cameraEye: frameContext.cameraEye),
                             Frustum(pv: cameraMatrix))
        }
        centre = frameContext.mapCameraState.centerWorldMercator
        flatRenderState = frameContext.resolvedPresentation.flatRenderState
    }

    func nearestTiles(zoom: Int, limit: Int) -> [VisibleTile] {
        switch surface {
        case let .flat(polygon):
            guard let polygon else { return [] }
            return TileGridCoverage.flat(zoom: zoom, limit: limit, polygon: polygon,
                                         flatRenderState: flatRenderState, centre: centre)
        case let .globe(inputs, frustum):
            return TileGridCoverage.globe(zoom: zoom, limit: limit, inputs: inputs, frustum: frustum, centre: centre)
        }
    }

    /// The copies of the world a tile shows in: none when it is out of
    /// view.
    func copies(showing tile: Tile) -> [VisibleTile] {
        switch surface {
        case let .flat(polygon):
            guard let polygon else { return [] }
            return TileGridCoverage.flatCopies(showing: tile, polygon: polygon, flatRenderState: flatRenderState)
        case let .globe(inputs, frustum):
            return TileGridCoverage.globeShows(tile, inputs: inputs, frustum: frustum) ? [VisibleTile(tile: tile)] : []
        }
    }

    func gpuTile(_ tile: VisibleTile, flags: UInt32) -> TileGridTileGPU {
        let flat = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z,
                                                                worldWrap: tile.worldWrap,
                                                                flatRenderPan: flatRenderState.pan,
                                                                renderMapSize: flatRenderState.renderMapSize)
        let sphere = GlobeSurfaceTileUniform(tile: tile.tile)
        return TileGridTileGPU(flatOrigin: SIMD2(flat.x, flat.y),
                               flatSize: flat.z,
                               referenceWorldX: sphere.referenceWorldX,
                               uvOrigin: sphere.uvOrigin,
                               uvScale: sphere.uvScale,
                               flags: flags)
    }
}
