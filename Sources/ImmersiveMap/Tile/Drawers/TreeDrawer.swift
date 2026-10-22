// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum TreeDrawer {
    /// One tile's trees this frame: the placement they draw from, how
    /// many of its trees (a prefix, the tile's being sorted by priority),
    /// and how far the tile has risen out of the ground (`ExtrusionRise`).
    struct Item {
        let placement: PlaceTile
        let instanceCount: Int
        let riseScale: Float
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

        forEachTile(items: items, mesh: mesh, flatRenderState: flatRenderState, renderEncoder: renderEncoder) { item, trees, tile in
            renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: tile.z)
                                                   | TileSourceStencilPriority.surfaceMaskBit)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: levelOfDetail.indexCount,
                                                indexType: .uint16,
                                                indexBuffer: mesh.buffer,
                                                indexBufferOffset: levelOfDetail.indexOffset,
                                                instanceCount: min(item.instanceCount, trees.count))
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

        forEachTile(items: items, mesh: mesh, flatRenderState: flatRenderState, renderEncoder: renderEncoder) { item, trees, _ in
            renderEncoder.drawPrimitives(type: .triangle,
                                         vertexStart: 0,
                                         vertexCount: 6,
                                         instanceCount: min(item.instanceCount, trees.count))
        }

        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Binds each item's tile (its matrix at vertex buffer 3 and its
    /// trees at vertex buffer 4) and hands it to `draw`.
    private static func forEachTile(items: [Item],
                                    mesh: TreeModelMesh,
                                    flatRenderState: FlatRenderState,
                                    renderEncoder: MTLRenderCommandEncoder,
                                    _ draw: (Item, TileBufferView, Tile) -> Void) {
        for item in items where item.instanceCount > 0 {
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
            renderEncoder.setVertexBuffer(trees.buffer, offset: trees.offset, index: 4)
            draw(item, trees, tile)
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
