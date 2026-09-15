// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The tile-ownership stencil prepass of the flat passes: before anything
/// else draws, one full-extent quad per unique source of the main coverage
/// writes the tile-priority stencil (finest first, greaterEqual + replace,
/// no color and no depth). The ground's sources overlap (a coarse parent
/// under fine children, substitutes at full extent), and every ground pass
/// tests these marks, so which source owns a pixel is settled before any
/// of them draws and does not depend on their draw order or rank depths.
/// The buildings do not test them: the building coverage is a partition
/// (`BuildingCoveragePlanner`).
final class TileOwnershipRenderSubsystem: RenderSubsystem {
    let name: String = "TileOwnership"

    private let pipeline: TileOwnershipPipeline
    private let tileOwnershipWriteState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    init(pipeline: TileOwnershipPipeline,
         tileOwnershipWriteState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.pipeline = pipeline
        self.tileOwnershipWriteState = tileOwnershipWriteState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .tileOwnership,
              frameContext.renderSurfaceMode == .flat else {
            return
        }
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        guard placements.isEmpty == false else { return }

        // The same dedupe key as the flat surface drawer: the world-wrap
        // copies at the seam are distinct quads of the same tile.
        struct SourceKey: Hashable {
            let tile: Tile
            let loop: Int8
        }
        var seenSources = Set<SourceKey>()
        var uniqueSources: [(tile: Tile, loop: Int8)] = []
        uniqueSources.reserveCapacity(placements.count)
        for placeTile in placements {
            let key = SourceKey(tile: placeTile.metalTile.tile, loop: placeTile.placeIn.loop)
            if seenSources.insert(key).inserted {
                uniqueSources.append((placeTile.metalTile.tile, placeTile.placeIn.loop))
            }
        }

        pipeline.selectPipeline(renderEncoder: encoder)
        encoder.setDepthStencilState(tileOwnershipWriteState)
        encoder.setCullMode(.none)
        var cameraUniformValue = frameContext.cameraUniform
        encoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        for source in uniqueSources {
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: source.tile.x,
                                                                             y: source.tile.y,
                                                                             z: source.tile.z,
                                                                             loop: source.loop,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            var modelMatrix = Matrix.translationMatrix(x: originAndSize.x,
                                                       y: originAndSize.y,
                                                       z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale)
            encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            encoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: source.tile.z))
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
