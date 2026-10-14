// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The ring prepass of the flat map: before the ground draws, every
/// coverage target (`VisibleContentState.visibleTiles`) writes the rank of
/// its ring (`FlatTileStencilPacking`) into the tile-priority stencil
/// (`TileSourceStencilPriority`) over its own extent, the farthest ring's
/// targets first and the nearest ring's last, nothing else. So a tile
/// draws on its own ring and on the farther ones, and never on a nearer
/// ring, however far its geometry reaches: a ring's tiles are the ring's,
/// and a source placed in a nearer ring's slot as a stand-in carries that
/// ring's rank and draws there too. The farthest ring's targets need no
/// mark: the cleared stencil, rank 0, lets every source through, as its
/// own rank 1 would.
///
/// A target is marked on the ground, not on the plane: its grid
/// (`RasterTileGrid`) raised by its terrain where the frame is on the
/// relief, as a raster tile is drawn, so the marks lie where the ground
/// is drawn. A plain square on the plane would not do: the plane is the
/// datum's height, the terrain under the point the camera looks at, and
/// a plain lying below it, seen from a hill, projects below the square's
/// far edge on screen, into the nearer ring's mark, and vanished. Where a
/// far ring's hill stands over a nearer ring's ground on screen the
/// nearer ring's mark, written last, still wins, and the hill is cut
/// along the nearer ground's edge: the depth is not read here.
final class RingStencilRenderSubsystem: RenderSubsystem {
    let name: String = "RingStencil"

    private let pipeline: RingStencilPipeline
    private let grid: RasterTileGrid
    private let ringStencilWriteState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let groundReliefStore: GroundReliefStore?
    private let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    init(device: MTLDevice,
         pipeline: RingStencilPipeline,
         ringStencilWriteState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         groundReliefStore: GroundReliefStore? = nil,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings = .init()) {
        self.pipeline = pipeline
        self.grid = RasterTileGrid(device: device)
        self.ringStencilWriteState = ringStencilWriteState
        self.depthDisabledState = depthDisabledState
        self.groundReliefStore = groundReliefStore
        self.groundFlattening = groundFlattening
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .ringStencil,
              frameContext.renderSurfaceMode == .flat else {
            return
        }
        let visibleContent = frameContext.visibleContent
        let packing = FlatTileStencilPacking(bands: visibleContent.flatRingBands, targetZoom: visibleContent.tileZoomLevel)
        // The targets of every ring but the farthest, the farthest ring's
        // first: a target reaching into a nearer ring is overwritten there
        // by the nearer ring's own targets.
        let targets = visibleContent.visibleTiles
            .map { (target: $0, rank: packing.rank(slotZoom: $0.z)) }
            .filter { $0.rank > 1 }
            .sorted { $0.rank < $1.rank }
        guard targets.isEmpty == false else { return }
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState

        encoder.pushDebugGroup("ground.ringStencil")
        encoder.setDepthStencilState(ringStencilWriteState)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        var cameraUniform = frameContext.cameraUniform
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        // The relief variant for a target whose terrain is in, the plain
        // one for the rest, selected only where it changes from the last
        // draw.
        var selectedRelief: Bool?
        for (target, rank) in targets {
            let tile = target.tile
            let relief = groundReliefStore?.relief(for: tile, terrainZoom: GroundReliefStore.terrainZoom(forTargetZoom: tile.z))
            let cells = relief == nil ? 0 : groundFlattening.grid(forTileZoom: tile.z)
            guard let mesh = grid.mesh(forTileZoom: tile.z, atLeast: cells) else { continue }
            if selectedRelief != (relief != nil) {
                selectedRelief = relief != nil
                encoder.setRenderPipelineState(relief != nil ? pipeline.flatReliefPipelineState : pipeline.flatPipelineState)
            }
            if let relief, let groundReliefStore {
                var uniform = GroundReliefUniform(relief: relief,
                                                  worldUnitsPerMetre: groundReliefStore.worldUnitsPerMetre(over: tile,
                                                                                                           renderMapSize: flatRenderState.renderMapSize),
                                                  datumMetres: groundReliefStore.datumMetres)
                encoder.setVertexTexture(relief.texture, index: 0)
                encoder.setVertexBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
            }
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             worldWrap: target.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            var modelMatrix = Matrix.translationMatrix(x: originAndSize.x,
                                                       y: originAndSize.y,
                                                       z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            encoder.setStencilReferenceValue(rank << UInt32(packing.zoomBits))
            encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: mesh.indexCount,
                                          indexType: .uint16,
                                          indexBuffer: mesh.indices,
                                          indexBufferOffset: 0)
        }
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(depthDisabledState)
        encoder.popDebugGroup()
    }

    func handleMemoryWarning() {}

    func evict() {}
}
