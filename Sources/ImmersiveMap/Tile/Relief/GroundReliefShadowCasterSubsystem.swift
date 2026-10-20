// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The mountains' shadows: the ground relief drawn into the shadow map
/// (`RenderLayer.shadowCasters` and `.farShadowCasters`, one pass a
/// window), as the buildings are, so a ridge darkens
/// the valley behind it from the scene's sun, and everything that reads
/// the shadow map on the relief takes the shadow (the ground's relief
/// variants, Tile.metal and TileRaster.metal, the buildings, the models).
///
/// Every point of the ground casts once, from the surface the frame shows
/// there. Placements overlap (a finer one inside a coarser one, a child
/// target under its parent), and the tile-priority stencil shows the
/// finest square's source over each point, so each placement casts from
/// its square less the finer squares inside it
/// (`PlacementGroundSquare.squares(of:)`), split into the descendants left
/// over. A square left whole is drawn too: the coarse surface under a
/// finer one is smoothed, lies above the true valleys, and would darken
/// them with shadows of hills nobody sees.
/// The heights are the ones the ground draws with: the source tile's
/// relief at the deepest ring the source is placed in
/// (`FlatMapSurfaceDrawer`, `RasterTileRenderSubsystem`), narrowed to the
/// square drawn (`GroundRelief.narrowed(to:in:)`).
///
/// The square is the raster tiles' grid (`RasterTileGrid`), raised by
/// those heights, from the light, depth only. Its cells are the receiving
/// ground's, so the caster lies on the surface it shadows and a slope
/// does not shadow itself in bands: a raster source's raster grid
/// (`RasterTileGrid.reliefCells`), a vector source's flattening grid up
/// to `maximumVectorCells`, divided down to the square, the depth bias by
/// the slope covering the rest. The hillshade shades the slopes' own
/// faces (`ImmersiveMapHillshade`).
///
/// It draws when the mountains cast this frame
/// (`GroundReliefStore.castsShadowsThisFrame`), which opens the shadow pass
/// with no building in sight (`ShadowPassGateResolver`), and the pass runs
/// only when the map went stale (`ShadowMapReuseController`, the terrain's
/// `ShadowSignature` among what makes it so).
final class GroundReliefShadowCasterSubsystem: RenderSubsystem {
    let name: String = "GroundReliefShadowCasters"

    /// The most cells a side a vector placement's caster takes: the near
    /// ring's flattening grids reach 256, four times the triangles for
    /// shadows of the same shape.
    static let maximumVectorCells = 128
    /// The depth bias by the slope, in the light's depth: the caster's
    /// grid and the receiving ground meet with a sliver of numeric and
    /// grid difference, which would stripe the lit slopes.
    static let slopeDepthBias: Float = 4

    private let pipeline: RasterTilePipeline
    private let grid: RasterTileGrid
    private let depthState: MTLDepthStencilState
    private let groundReliefStore: GroundReliefStore?
    private let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    init(device: MTLDevice,
         pipeline: RasterTilePipeline,
         depthState: MTLDepthStencilState,
         groundReliefStore: GroundReliefStore?,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings) {
        self.pipeline = pipeline
        self.grid = RasterTileGrid(device: device)
        self.depthState = depthState
        self.groundReliefStore = groundReliefStore
        self.groundFlattening = groundFlattening
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard let slot = ShadowCascadeSlot(casterLayer: layer),
              frameContext.renderSurfaceMode == .flat,
              let store = groundReliefStore, store.castsShadowsThisFrame,
              let lightProjectionView = frameContext.shadowFrameState?.lightProjectionView(for: slot) else { return }
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        // The horizon backdrop is no ground of the planner's and casts nothing.
        let casters = PlacementGroundSquare.squares(of: placements.filter { $0.isHorizonBackdrop == false })
        guard casters.isEmpty == false else { return }
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        let rasterSizeByTile = RasterTileGrid.rasterSizesBySource(placements)

        encoder.pushDebugGroup("relief.shadowCasters")
        encoder.setRenderPipelineState(pipeline.reliefShadowPipelineState)
        encoder.setDepthStencilState(depthState)
        // Pancaked, as the buildings' casters: a mountain behind the
        // light's near plane still casts.
        encoder.setDepthClipMode(.clamp)
        encoder.setCullMode(.none)
        encoder.setDepthBias(0, slopeScale: Self.slopeDepthBias, clamp: 0)
        var casterUniform = ShadowCasterUniform(lightProjectionView: lightProjectionView)
        encoder.setVertexBytes(&casterUniform, length: MemoryLayout<ShadowCasterUniform>.stride, index: 1)
        // A source split into several squares looks its relief up once.
        var sourceReliefs: [PlacementGroundSquare.Source: (relief: GroundRelief, cells: Int)?] = [:]
        for caster in casters {
            let source = caster.source
            let resolved: (relief: GroundRelief, cells: Int)?
            if let cached = sourceReliefs[source] {
                resolved = cached
            } else {
                resolved = source.displacement.flatMap { store.relief(for: source.tile, terrain: $0) }.map { relief in
                    let gridCells = groundFlattening.grid(forTileZoom: source.tile.z)
                    let cells = rasterSizeByTile[source.tile].map {
                        RasterTileGrid.reliefCells(gridCells: gridCells, relief: relief, rasterSize: $0)
                    } ?? min(gridCells, Self.maximumVectorCells)
                    return (relief, cells)
                }
                sourceReliefs[source] = resolved
            }
            guard let resolved else { continue }
            let square = caster.square.tile
            // The source's cells over the part of it drawn, on the same lines.
            let squareCells = PlacementGroundSquare.cells(ofSource: resolved.cells, sourceZoom: source.tile.z, squareZoom: square.z)
            guard let mesh = grid.mesh(forTileZoom: square.z, atLeast: squareCells) else { continue }
            GroundReliefUniform.bind(resolved.relief.narrowed(to: square, in: source.tile),
                                     over: square,
                                     store: store,
                                     renderMapSize: flatRenderState.renderMapSize,
                                     encoder: encoder)
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: square.x,
                                                                             y: square.y,
                                                                             z: square.z,
                                                                             worldWrap: caster.square.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            var modelMatrix = Matrix.translationMatrix(x: originAndSize.x, y: originAndSize.y, z: 0)
                * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: mesh.indexCount,
                                          indexType: mesh.indexType,
                                          indexBuffer: mesh.indices,
                                          indexBufferOffset: 0)
        }
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        encoder.setDepthClipMode(.clip)
        encoder.popDebugGroup()
    }

    func handleMemoryWarning() {}

    func evict() {}
}
