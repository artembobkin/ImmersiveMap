// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The placement prepass, on either surface: before any ground draws, the
/// ground of every placement is marked in the tile-priority stencil with
/// the zoom of its source (`TileSourceStencilPriority`), the placements'
/// squares drawn coarse first so a finer placement's mark lies over a
/// coarser one's. The square is the placement's `placeIn`: the slot for
/// a tile in its own slot and for an ancestor standing in, the stand-in's
/// own square for a descendant. The ground passes then paint by
/// equality, each source the ground the planner gave it. The square is
/// the raster tile's grid (`RasterTileGrid`) through the raster tile's
/// vertex paths: on the plane raised by the relief like the ground is,
/// by the terrain of the slot's ring, so the marks lie where the ground
/// lies, and on the sphere projected as the ground is, resting or in the
/// morph.
///
/// On the relief the squares overlap on the screen as well as on the
/// ground: a near mountain stands in front of the ground of the squares
/// behind it, whatever their zoom, and the mark of a pixel has to be the
/// placement whose ground is seen there, which the order of the squares
/// cannot tell. So the relief takes two passes. The first draws the
/// ground's depth: every point of the ground once, from the placement the
/// planner gave it (`PlacementGroundSquare.squares(of:)`), each square on
/// its source's own grid lines, as its ground is drawn, so the surface is
/// the ground's and no two placements compete for one point of it. Then
/// the marks, every placement's whole square, coarse first as on the
/// plane, tested against that depth: a square's mark lands only where its
/// ground is the one in front, so the ground behind a mountain keeps the
/// mountain's mark, and a coarse square's mark inside a finer square lies
/// under the finer mark that follows it, however its coarser grid bulges
/// over the finer one, since the finer square's own surface is the depth
/// it is tested against. That depth serves the marks alone: once they are
/// written it is put back to the cleared far plane (one triangle over the
/// screen, `placementDepthResetVertexShader`), so the ground passes meet
/// the depth they always met, their own. The ground's own triangulation
/// of a grid cell is not the grid's two triangles, and on a cliff the two
/// surfaces part by the cell's twist, which no bias covers: tested
/// against the grid's depth, whole cells of the fills would drop out. A
/// coarse square's whole mark still covers the slivers along a finer
/// square's edge where the two grids part. The plane needs none of this:
/// its squares never share a pixel.
final class PlacementStencilRenderSubsystem: RenderSubsystem {
    let name: String = "PlacementStencil"

    /// How far behind the ground's surface its depth is written in the
    /// relief's first pass, in the depth's units and in units of its slope
    /// per pixel: enough for a square's mark, the same grid drawn again,
    /// to pass `lessEqual` against it through the rasterizer's rounding,
    /// and no more, so the ground behind a mountain's silhouette fails the
    /// test right at the silhouette.
    static let groundDepthBias: Float = 1
    static let groundDepthSlopeBias: Float = 1

    private let pipeline: PlacementStencilPipeline
    private let grid: RasterTileGrid
    private let placementStencilWriteState: MTLDepthStencilState
    private let placementDepthWriteState: MTLDepthStencilState
    private let placementStencilReliefWriteState: MTLDepthStencilState
    private let placementDepthResetState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let groundReliefStore: GroundReliefStore?
    private let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    /// - Parameter placementStencilWriteState: the plane's and the
    ///   sphere's marks, the depth untouched.
    /// - Parameter placementDepthWriteState: the relief's first pass, the
    ///   ground's depth, the stencil untouched.
    /// - Parameter placementStencilReliefWriteState: the relief's marks,
    ///   tested against that depth.
    /// - Parameter placementDepthResetState: the far plane written back
    ///   over the screen after the marks.
    init(device: MTLDevice,
         pipeline: PlacementStencilPipeline,
         placementStencilWriteState: MTLDepthStencilState,
         placementDepthWriteState: MTLDepthStencilState,
         placementStencilReliefWriteState: MTLDepthStencilState,
         placementDepthResetState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         groundReliefStore: GroundReliefStore? = nil,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings = .init()) {
        self.pipeline = pipeline
        self.grid = RasterTileGrid(device: device)
        self.placementStencilWriteState = placementStencilWriteState
        self.placementDepthWriteState = placementDepthWriteState
        self.placementStencilReliefWriteState = placementStencilReliefWriteState
        self.placementDepthResetState = placementDepthResetState
        self.depthDisabledState = depthDisabledState
        self.groundReliefStore = groundReliefStore
        self.groundFlattening = groundFlattening
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .placementStencil else { return }
        // Coarse squares first: a finer placement inside a coarser one
        // (a descendant standing in, a child target under its parent)
        // marks over it.
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
            .sorted { $0.placeIn.z < $1.placeIn.z }
        guard placements.isEmpty == false else { return }

        encoder.pushDebugGroup("ground.placementStencil")
        encoder.setDepthStencilState(placementStencilWriteState)
        // Every grid triangle is counter-clockwise in render space and
        // neither surface mirrors: back faces are culled, which on the
        // sphere removes its far side.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        var cameraUniform = frameContext.cameraUniform
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        switch frameContext.renderSurfaceMode {
        case .flat:
            encodeFlat(placements: placements, encoder: encoder, frameContext: frameContext)
        case .spherical:
            encodeSphere(placements: placements, encoder: encoder, frameContext: frameContext)
        }
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(depthDisabledState)
        encoder.popDebugGroup()
    }

    private func encodeFlat(placements: [PlaceTile], encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        guard let store = groundReliefStore, store.isActive else {
            // The plane: the marks alone, the depth untouched.
            encodeFlatMarks(placements: placements, encoder: encoder, flatRenderState: flatRenderState, store: nil)
            return
        }
        // The horizon backdrop first, flat and with no depth: its mark is
        // under every other's, wherever the ground is, and it takes no
        // part in the ground's depth, where the plane it lies on would win
        // the valleys under the plane from the ground that is there.
        let backdrops = placements.filter(\.isHorizonBackdrop)
        let ground = placements.filter { $0.isHorizonBackdrop == false }
        if backdrops.isEmpty == false {
            encodeFlatMarks(placements: backdrops, encoder: encoder, flatRenderState: flatRenderState, store: nil)
        }
        // The relief: the ground's depth, then the marks tested against it.
        encoder.setDepthStencilState(placementDepthWriteState)
        encoder.setDepthBias(Self.groundDepthBias, slopeScale: Self.groundDepthSlopeBias, clamp: 0)
        encodeFlatGroundDepth(placements: ground, encoder: encoder, flatRenderState: flatRenderState, store: store)
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        encoder.setDepthStencilState(placementStencilReliefWriteState)
        encodeFlatMarks(placements: ground, encoder: encoder, flatRenderState: flatRenderState, store: store)
        // The depth back to the far plane: it was the marks' to test
        // against, and the ground meets the cleared depth as before.
        encoder.pushDebugGroup("ground.placementDepthReset")
        encoder.setDepthStencilState(placementDepthResetState)
        encoder.setRenderPipelineState(pipeline.depthResetPipelineState)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.popDebugGroup()
    }

    /// A source's ground as the ground draws it: its relief out of the
    /// terrain its placements are bound to, and its grid's cells a side. A
    /// raster source's grid is the raster ground's
    /// (`RasterTileGrid.reliefCells`), at its raster size; a vector
    /// source's the flattening's, as the vector ground has, and so has a
    /// raster source drawn as geometry elsewhere
    /// (`RasterTileRenderSubsystem`). No relief on the plane.
    private struct SourceGround {
        let relief: GroundRelief?
        let cells: Int
    }

    private func sourceGround(tile: Tile,
                              displacement: Tile?,
                              rasterSizeByTile: [Tile: Int],
                              store: GroundReliefStore?) -> SourceGround {
        let gridCells = groundFlattening.grid(forTileZoom: tile.z)
        guard let displacement, let relief = store?.relief(for: tile, terrain: displacement) else {
            return SourceGround(relief: nil, cells: 0)
        }
        let cells = rasterSizeByTile[tile].map {
            RasterTileGrid.reliefCells(gridCells: gridCells, relief: relief, rasterSize: $0)
        } ?? gridCells
        return SourceGround(relief: relief, cells: cells)
    }

    /// The relief's first pass: every point of the ground once, from the
    /// placement the planner gave it, each square a part of its source's
    /// grid on the source's own lines, lifted by the source's relief
    /// narrowed to the square. Depth only.
    private func encodeFlatGroundDepth(placements: [PlaceTile],
                                       encoder: MTLRenderCommandEncoder,
                                       flatRenderState: FlatRenderState,
                                       store: GroundReliefStore) {
        let rasterSizeByTile = RasterTileGrid.rasterSizesBySource(placements)
        var grounds: [PlacementGroundSquare.Source: SourceGround] = [:]
        var selectedRelief: Bool?
        encoder.pushDebugGroup("ground.placementDepth")
        for square in PlacementGroundSquare.squares(of: placements) {
            let source = square.source
            let ground: SourceGround
            if let known = grounds[source] {
                ground = known
            } else {
                ground = sourceGround(tile: source.tile, displacement: source.displacement, rasterSizeByTile: rasterSizeByTile, store: store)
                grounds[source] = ground
            }
            let tile = square.square.tile
            // The source's cells over the part of it drawn, on the same
            // lines, exactly: the zoom's floor would put the part's
            // vertices between the source's.
            let squareCells = PlacementGroundSquare.cells(ofSource: ground.cells, sourceZoom: source.tile.z, squareZoom: tile.z)
            let mesh: RasterTileGrid.Mesh?
            if ground.relief != nil {
                mesh = grid.mesh(cells: squareCells)
            } else {
                mesh = grid.mesh(forTileZoom: tile.z)
            }
            guard let mesh else { continue }
            selectPipeline(relief: ground.relief != nil, selected: &selectedRelief, encoder: encoder)
            if let relief = ground.relief {
                GroundReliefUniform.bind(relief.narrowed(to: tile, in: source.tile),
                                         over: tile,
                                         store: store,
                                         renderMapSize: flatRenderState.renderMapSize,
                                         encoder: encoder)
            }
            setModelMatrix(tile: tile, worldWrap: square.square.worldWrap, flatRenderState: flatRenderState, encoder: encoder)
            draw(mesh: mesh, encoder: encoder)
        }
        encoder.popDebugGroup()
    }

    /// The marks: every placement's whole square, coarse first, each on
    /// its source's grid (the source's cells over the square, as the
    /// relief's first pass drew them, so a square's mark meets its own
    /// depth), lifted by the source's relief narrowed to the square, or
    /// on the plane without a store.
    private func encodeFlatMarks(placements: [PlaceTile],
                                 encoder: MTLRenderCommandEncoder,
                                 flatRenderState: FlatRenderState,
                                 store: GroundReliefStore?) {
        let rasterSizeByTile = RasterTileGrid.rasterSizesBySource(placements)
        // A source's relief is one terrain wherever it draws, so a mark
        // meets the depth the first pass drew from the same heights.
        let displacements = PlacementGroundSquare.displacements(of: placements)
        var grounds: [PlacementGroundSquare.Source: SourceGround] = [:]
        var selectedRelief: Bool?
        for placement in placements {
            let source = placement.metalTile.tile
            let tile = placement.placeIn.tile
            let sourceKey = PlacementGroundSquare.Source(
                tile: source,
                worldWrap: placement.placeIn.worldWrap,
                displacement: displacements[VisibleTile(tile: source, worldWrap: placement.placeIn.worldWrap)] ?? placement.displacement)
            let ground: SourceGround
            if let known = grounds[sourceKey] {
                ground = known
            } else {
                ground = sourceGround(tile: source, displacement: sourceKey.displacement, rasterSizeByTile: rasterSizeByTile, store: store)
                grounds[sourceKey] = ground
            }
            let squareCells = PlacementGroundSquare.cells(ofSource: ground.cells, sourceZoom: source.z, squareZoom: tile.z)
            let mesh: RasterTileGrid.Mesh?
            if ground.relief != nil {
                mesh = grid.mesh(cells: squareCells)
            } else {
                mesh = grid.mesh(forTileZoom: tile.z)
            }
            guard let mesh else { continue }
            selectPipeline(relief: ground.relief != nil, selected: &selectedRelief, encoder: encoder)
            if let relief = ground.relief, let store {
                GroundReliefUniform.bind(relief.narrowed(to: tile, in: source),
                                         over: tile,
                                         store: store,
                                         renderMapSize: flatRenderState.renderMapSize,
                                         encoder: encoder)
            }
            setModelMatrix(tile: tile, worldWrap: placement.placeIn.worldWrap, flatRenderState: flatRenderState, encoder: encoder)
            encoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: source.z))
            draw(mesh: mesh, encoder: encoder)
        }
    }

    /// The relief variant for a square whose terrain is in, the plain one
    /// for the rest, selected only where it changes from the last draw.
    private func selectPipeline(relief: Bool, selected: inout Bool?, encoder: MTLRenderCommandEncoder) {
        guard selected != relief else { return }
        selected = relief
        encoder.setRenderPipelineState(relief ? pipeline.flatReliefPipelineState : pipeline.flatPipelineState)
    }

    private func setModelMatrix(tile: Tile, worldWrap: Int8, flatRenderState: FlatRenderState, encoder: MTLRenderCommandEncoder) {
        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         worldWrap: worldWrap,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / 4096.0
        var modelMatrix = Matrix.translationMatrix(x: originAndSize.x,
                                                   y: originAndSize.y,
                                                   z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
        encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
    }

    /// The sphere has one copy of the world: a placement's square is its
    /// tile's place on the sphere, as the raster tile draws it.
    private func encodeSphere(placements: [PlaceTile], encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        let globe = frameContext.globeRenderUniform
        let pureSphere = GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                            transition: globe.transition)
        encoder.setRenderPipelineState(pureSphere ? pipeline.spherePurePipelineState : pipeline.sphereMorphPipelineState)
        var globeValue = globe
        var globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: frameContext.cameraUniform.matrix)
        encoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 8)
        encoder.setVertexBytes(&globeFrame, length: MemoryLayout<GlobeFrameConstantsUniform>.stride, index: 10)
        for placement in placements {
            let tile = placement.placeIn.tile
            guard let mesh = grid.mesh(forTileZoom: tile.z) else { continue }
            var surfaceTile = GlobeSurfaceTileUniform(tile: tile)
            encoder.setVertexBytes(&surfaceTile, length: MemoryLayout<GlobeSurfaceTileUniform>.stride, index: 9)
            encoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: placement.metalTile.tile.z))
            draw(mesh: mesh, encoder: encoder)
        }
    }

    private func draw(mesh: RasterTileGrid.Mesh, encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: mesh.indexCount,
                                      indexType: mesh.indexType,
                                      indexBuffer: mesh.indices,
                                      indexBufferOffset: 0)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
