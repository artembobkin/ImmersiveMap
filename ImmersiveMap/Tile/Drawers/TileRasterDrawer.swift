// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Draws the rasterized sources of the flat world pass: one textured quad
/// over each tile's extent (TileRaster.metal), under the ground owner
/// state, so the quad writes the ground's rank band and owns the
/// tile-priority stencil like the vector ground would. Finest first, like
/// the vector sources.
enum TileRasterDrawer {
    struct Source {
        let tile: Tile
        let worldWrap: Int8
        let texture: MTLTexture
    }

    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     sources: [Source],
                     flatRenderState: FlatRenderState,
                     groundShadowMask: GroundShadowMaskBinding,
                     pipeline: TileRasterPipeline,
                     groundOwnerState: MTLDepthStencilState) {
        guard sources.isEmpty == false else { return }
        renderEncoder.pushDebugGroup("ground.raster")
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(groundOwnerState)
        renderEncoder.setCullMode(.none)
        var cameraUniformValue = cameraUniform
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        var shadowUniformValue = groundShadowMask.uniform
        renderEncoder.setFragmentBytes(&shadowUniformValue, length: MemoryLayout<ShadowUniform>.stride, index: 3)
        renderEncoder.setFragmentTexture(groundShadowMask.texture, index: 1)
        for source in sources.sorted(by: { $0.tile.z > $1.tile.z }) {
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: source.tile.x,
                                                                             y: source.tile.y,
                                                                             z: source.tile.z,
                                                                             worldWrap: source.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            var modelMatrix = Matrix.translationMatrix(x: originAndSize.x, y: originAndSize.y, z: 0)
                * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: source.tile.z))
            renderEncoder.setFragmentTexture(source.texture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        renderEncoder.popDebugGroup()
    }
}
