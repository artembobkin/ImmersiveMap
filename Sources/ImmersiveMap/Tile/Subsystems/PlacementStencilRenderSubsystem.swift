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
final class PlacementStencilRenderSubsystem: RenderSubsystem {
    let name: String = "PlacementStencil"

    private let pipeline: PlacementStencilPipeline
    private let grid: RasterTileGrid
    private let placementStencilWriteState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let groundReliefStore: GroundReliefStore?
    private let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    init(device: MTLDevice,
         pipeline: PlacementStencilPipeline,
         placementStencilWriteState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         groundReliefStore: GroundReliefStore? = nil,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings = .init()) {
        self.pipeline = pipeline
        self.grid = RasterTileGrid(device: device)
        self.placementStencilWriteState = placementStencilWriteState
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
        // The relief variant for a square whose terrain is in, the plain
        // one for the rest, selected only where it changes from the last
        // draw.
        var selectedRelief: Bool?
        for placement in placements {
            let tile = placement.placeIn.tile
            let relief = groundReliefStore?.relief(for: tile,
                                                   terrainZoom: GroundReliefStore.terrainZoom(forTargetZoom: placement.slot.z))
            let cells = relief == nil ? 0 : groundFlattening.grid(forTileZoom: tile.z)
            guard let mesh = grid.mesh(forTileZoom: tile.z, atLeast: cells) else { continue }
            if selectedRelief != (relief != nil) {
                selectedRelief = relief != nil
                encoder.setRenderPipelineState(relief != nil ? pipeline.flatReliefPipelineState : pipeline.flatPipelineState)
            }
            if let relief, let groundReliefStore {
                GroundReliefUniform.bind(relief,
                                         over: tile,
                                         datumMetres: groundReliefStore.datumMetres,
                                         renderMapSize: flatRenderState.renderMapSize,
                                         encoder: encoder)
            }
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             worldWrap: placement.placeIn.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            var modelMatrix = Matrix.translationMatrix(x: originAndSize.x,
                                                       y: originAndSize.y,
                                                       z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            encoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: placement.metalTile.tile.z))
            draw(mesh: mesh, encoder: encoder)
        }
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
                                      indexType: .uint16,
                                      indexBuffer: mesh.indices,
                                      indexBufferOffset: 0)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
