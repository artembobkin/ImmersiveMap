// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum TreeDrawer {
    /// One tile's trees this frame: the placement they draw from, which
    /// of its trees (`instanceRanges`, a prefix of each quarter drawn, a
    /// quarter's trees being sorted by priority, or of the whole tile's),
    /// and how far the tile has risen out of the ground (`ExtrusionRise`).
    struct Item {
        let placement: PlaceTile
        let instanceRanges: [Range<Int>]
        let riseScale: Float

        /// The first `share` of each run of `starts` that `quarters`
        /// draws (`TileQuarters.runs`, a quarter at a time, never joined:
        /// each is thinned on its own), at least one tree of a run that
        /// has any. `count` is the tile's trees.
        static func instanceRanges(count: Int, starts: [Int], quarters: UInt8, share: Float) -> [Range<Int>] {
            let runs: [Range<Int>]
            if starts.count == TileQuarters.count + 1 {
                runs = (0..<TileQuarters.count).compactMap { quarter in
                    quarters & (1 << quarter) != 0 ? starts[quarter]..<starts[quarter + 1] : nil
                }
            } else {
                runs = quarters == TileQuarters.all ? [0..<count] : []
            }
            return runs.compactMap { run in
                guard run.isEmpty == false else { return nil }
                let drawn = min(run.count, max(Int((Float(run.count) * share).rounded(.up)), 1))
                return run.lowerBound..<(run.lowerBound + drawn)
            }
        }
    }

    /// The share of the model's height its crown's centre stands at, and
    /// of its radius the crown spans: what the shadow disc is sized by.
    /// The model's crown fills the upper two thirds of its height, over a
    /// trunk a third of it.
    static let crownCentreHeightShare: Float = 0.62
    static let crownRadiusShare: Float = 0.9

    /// The trees of the frame's tiles, instanced from the model's level
    /// `level`, opaque with depth test and depth write, straight into the
    /// world pass as the buildings are, in the colours of `palette`.
    /// `lightDirection` points towards the light.
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     items: [Item],
                     mesh: TreeModelMesh,
                     level: Int,
                     palette: ImmersiveMapTreePalette,
                     flatRenderState: FlatRenderState,
                     lightDirection: SIMD3<Float>,
                     pipeline: TreePipeline,
                     stencilTestState: MTLDepthStencilState,
                     depthDisabledState: MTLDepthStencilState) {
        guard items.isEmpty == false else { return }
        let levelOfDetail = mesh.contents.levels[min(max(level, 0), mesh.contents.levels.count - 1)]
        var cameraUniformValue = cameraUniform
        var frameUniform = TreeFrameUniform(mesh: mesh, palette: palette, lightDirection: lightDirection)

        // The model's triangles are wound counter-clockwise seen from
        // outside; the ground is declared the same in this encoder.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)
        renderEncoder.setRenderPipelineState(pipeline.pipelineState)
        renderEncoder.setDepthStencilState(stencilTestState)
        renderEncoder.setVertexBuffer(mesh.buffer, offset: levelOfDetail.vertexOffset, index: 0)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&frameUniform, length: MemoryLayout<TreeFrameUniform>.stride, index: 7)
        renderEncoder.setFragmentBytes(&frameUniform, length: MemoryLayout<TreeFrameUniform>.stride, index: 7)

        forEachTile(items: items, mesh: mesh, flatRenderState: flatRenderState, renderEncoder: renderEncoder) { _, _, tile, instanceCount in
            renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: tile.z)
                                                   | TileSourceStencilPriority.surfaceMaskBit)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: levelOfDetail.indexCount,
                                                indexType: .uint16,
                                                indexBuffer: mesh.buffer,
                                                indexBufferOffset: levelOfDetail.indexOffset,
                                                instanceCount: instanceCount)
        }

        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// The shadow discs of the same trees, multiplied into the ground
    /// after the roads: `shadowUniform` gives the darkening and the tint
    /// the shadow map gives every other shadow, `groundDepthState` keeps
    /// a disc off the buildings standing nearer than its ground.
    static func drawShadows(renderEncoder: MTLRenderCommandEncoder,
                            cameraUniform: CameraUniform,
                            shadowUniform: ShadowUniform,
                            items: [Item],
                            mesh: TreeModelMesh,
                            palette: ImmersiveMapTreePalette,
                            flatRenderState: FlatRenderState,
                            lightDirection: SIMD3<Float>,
                            pipeline: TreePipeline,
                            groundDepthState: MTLDepthStencilState,
                            depthDisabledState: MTLDepthStencilState) {
        guard items.isEmpty == false, shadowUniform.strength > 0 else { return }
        var cameraUniformValue = cameraUniform
        var frameUniform = TreeFrameUniform(mesh: mesh, palette: palette, lightDirection: lightDirection)
        var shadowUniformValue = shadowUniform

        renderEncoder.setCullMode(.none)
        renderEncoder.setRenderPipelineState(pipeline.shadowPipelineState)
        renderEncoder.setDepthStencilState(groundDepthState)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&frameUniform, length: MemoryLayout<TreeFrameUniform>.stride, index: 7)
        renderEncoder.setFragmentBytes(&shadowUniformValue, length: MemoryLayout<ShadowUniform>.stride, index: 5)

        forEachTile(items: items, mesh: mesh, flatRenderState: flatRenderState, renderEncoder: renderEncoder) { _, _, _, instanceCount in
            renderEncoder.drawPrimitives(type: .triangle,
                                         vertexStart: 0,
                                         vertexCount: 6,
                                         instanceCount: instanceCount)
        }

        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Binds each item's tile (its matrix at vertex buffer 3) and, for
    /// each of its instance ranges, the trees of the range at vertex buffer
    /// 4, and hands it to `draw` with the range's count.
    private static func forEachTile(items: [Item],
                                    mesh: TreeModelMesh,
                                    flatRenderState: FlatRenderState,
                                    renderEncoder: MTLRenderCommandEncoder,
                                    _ draw: (Item, TileBufferView, Tile, Int) -> Void) {
        for item in items where item.instanceRanges.isEmpty == false {
            let metalTile = item.placement.metalTile
            guard let trees = metalTile.tileBuffers.trees else { continue }
            let tile = metalTile.tile
            let placeIn = item.placement.placeIn
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             worldWrap: placeIn.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / Float(TileCoordinateSpace.tileExtent)
            var tileUniform = TreeTileUniform(
                modelMatrix: Matrix.translationMatrix(x: originAndSize.x, y: originAndSize.y, z: 0)
                    * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale),
                heightScale: item.riseScale / mesh.contents.heightMetres)
            renderEncoder.setVertexBytes(&tileUniform, length: MemoryLayout<TreeTileUniform>.stride, index: 3)
            for range in item.instanceRanges {
                let clamped = range.clamped(to: 0..<trees.count)
                guard clamped.isEmpty == false else { continue }
                renderEncoder.setVertexBuffer(trees.buffer,
                                              offset: trees.offset + clamped.lowerBound * MemoryLayout<TreeInstance>.stride,
                                              index: 4)
                draw(item, trees, tile, clamped.count)
            }
        }
    }
}

/// Mirror of `TreeTile` in Trees.metal (vertex buffer 3): the tile's
/// matrix and what a unit of a tree's height is in the model's metres,
/// times the tile's rise.
struct TreeTileUniform {
    var modelMatrix: matrix_float4x4
    var heightScale: Float
    var padding: SIMD3<Float> = .zero

    init(modelMatrix: matrix_float4x4, heightScale: Float) {
        self.modelMatrix = modelMatrix
        self.heightScale = heightScale
    }
}

/// Mirror of `TreeFrame` in Trees.metal (vertex and fragment buffer 7):
/// the direction towards the light, the palette's colours, and the
/// crown's radius and centre height in the model's metres.
struct TreeFrameUniform {
    var lightDirection: SIMD4<Float>
    var crownColor: SIMD4<Float>
    var crownShadeColor: SIMD4<Float>
    var trunkColor: SIMD4<Float>
    var crown: SIMD4<Float>

    init(mesh: TreeModelMesh, palette: ImmersiveMapTreePalette, lightDirection: SIMD3<Float>) {
        self.lightDirection = SIMD4<Float>(simd_normalize(lightDirection), 0)
        crownColor = SIMD4<Float>(palette.crownColor, 1)
        crownShadeColor = SIMD4<Float>(palette.crownShadeColor, 1)
        trunkColor = SIMD4<Float>(palette.trunkColor, 1)
        crown = SIMD4<Float>(mesh.contents.radiusMetres * TreeDrawer.crownRadiusShare,
                             mesh.contents.heightMetres * TreeDrawer.crownCentreHeightShare,
                             0, 0)
    }
}
