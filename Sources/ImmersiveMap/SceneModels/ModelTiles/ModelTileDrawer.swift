// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// One model tile, placed for the frame and ready to encode.
struct ModelTileDrawItem {
    let mesh: ModelTileMesh
    /// Tile space into the frame's flat world: the matrix the map's own
    /// buildings of the same tile take, lowered while the tile comes up
    /// out of the ground (`ExtrusionRise`).
    let modelMatrix: matrix_float4x4
    /// Whether the tile is still partly under the ground, coming up: what
    /// is below the ground is not drawn.
    var isRising = false
}

enum ModelTileDrawer {
    /// The models in the world pass: opaque, depth tested and written,
    /// raising the surface mask bit where they land so the horizon's haze
    /// passes them by. They are drawn nearer in depth than they stand by
    /// `depthBias`, a share of their distance from the eye
    /// (`ModelArchiveSettings.depthBias`). A tile binds its buffer and its
    /// texture array once and draws every model it holds in one call.
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     shadowBinding: ShadowReceiverBinding,
                     items: [ModelTileDrawItem],
                     depthBias: Float,
                     pipeline: ModelTilePipeline,
                     surfaceMaskState: MTLDepthStencilState,
                     depthDisabledState: MTLDepthStencilState) {
        guard items.isEmpty == false else { return }

        var cameraUniformValue = cameraUniform
        renderEncoder.setCullMode(.back)
        // The models are counterclockwise-wound; Metal defaults to clockwise.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        var depthBiasValue = depthBias
        renderEncoder.setVertexBytes(&depthBiasValue, length: MemoryLayout<Float>.stride, index: 3)

        var shadowUniformValue = shadowBinding.uniform
        renderEncoder.setFragmentBytes(&shadowUniformValue, length: MemoryLayout<ShadowUniform>.stride, index: 4)
        renderEncoder.setFragmentTexture(shadowBinding.texture, index: 1)
        renderEncoder.setFragmentSamplerState(pipeline.baseColorSampler, index: 0)

        // Every standing tile under one pipeline and one state: one draw
        // a tile.
        renderEncoder.setRenderPipelineState(pipeline.pipelineState)
        renderEncoder.setDepthStencilState(surfaceMaskState)
        renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.surfaceMaskBit)
        for item in items where item.mesh.indexCount > 0 && item.isRising == false {
            bind(item, renderEncoder: renderEncoder, withTextures: true)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: item.mesh.indexCount,
                                                indexType: .uint32,
                                                indexBuffer: item.mesh.indexBuffer,
                                                indexBufferOffset: 0)
        }

        // A tile coming up out of the ground, with what is still below the
        // ground dropped.
        if items.contains(where: \.isRising) {
            renderEncoder.setRenderPipelineState(pipeline.belowGroundClippedPipelineState)
            for item in items where item.isRising && item.mesh.indexCount > 0 {
                bind(item, renderEncoder: renderEncoder, withTextures: true)
                renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                    indexCount: item.mesh.indexCount,
                                                    indexType: .uint32,
                                                    indexBuffer: item.mesh.indexBuffer,
                                                    indexBufferOffset: 0)
            }
        }

        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Depth-only replay of the tiles from the light's orthographic camera,
    /// cull `.none`, like the scene models' casters: one draw a tile.
    static func drawShadowCasters(renderEncoder: MTLRenderCommandEncoder,
                                  lightProjectionView: matrix_float4x4,
                                  items: [ModelTileDrawItem],
                                  pipeline: ModelTilePipeline,
                                  extrudedDepthState: MTLDepthStencilState) {
        guard items.isEmpty == false else { return }

        renderEncoder.setRenderPipelineState(pipeline.shadowPipelineState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setDepthClipMode(.clamp)

        var castersValue = ShadowCasterUniform(lightProjectionView: lightProjectionView)
        renderEncoder.setVertexBytes(&castersValue, length: MemoryLayout<ShadowCasterUniform>.stride, index: 1)

        for item in items {
            bind(item, renderEncoder: renderEncoder, withTextures: false)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: item.mesh.indexCount,
                                                indexType: .uint32,
                                                indexBuffer: item.mesh.indexBuffer,
                                                indexBufferOffset: 0)
        }

        renderEncoder.setDepthClipMode(.clip)
    }

    /// A tile's vertex buffer and matrix, and its texture array for a
    /// colour pass.
    private static func bind(_ item: ModelTileDrawItem,
                             renderEncoder: MTLRenderCommandEncoder,
                             withTextures: Bool) {
        var modelMatrix = item.modelMatrix
        renderEncoder.setVertexBuffer(item.mesh.vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 2)
        if withTextures {
            renderEncoder.setFragmentTexture(item.mesh.texture, index: 0)
        }
    }
}
