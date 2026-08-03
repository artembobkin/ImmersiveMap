// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit
import simd

/// One culled, anchor-resolved model ready to encode.
struct SceneModelDrawItem {
    let mesh: SceneModelMesh
    let modelMatrix: matrix_float4x4
}

enum SceneModelDrawer {
    /// Swift mirror of `SceneModelMaterial` in SceneModel.metal.
    struct SceneModelMaterialUniform {
        var baseColor: SIMD4<Float>
    }

    /// Opaque model geometry with depth test and depth write in the world pass.
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     shadowBinding: ShadowReceiverBinding,
                     items: [SceneModelDrawItem],
                     pipeline: SceneModelPipeline,
                     extrudedDepthState: MTLDepthStencilState,
                     depthDisabledState: MTLDepthStencilState) {
        guard items.isEmpty == false else { return }

        var cameraUniformValue = cameraUniform
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.back)
        // Model I/O meshes are counterclockwise-wound; Metal defaults to clockwise.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)

        var shadowUniformValue = shadowBinding.uniform
        renderEncoder.setFragmentBytes(&shadowUniformValue, length: MemoryLayout<ShadowUniform>.stride, index: 4)
        renderEncoder.setFragmentTexture(shadowBinding.texture, index: 1)
        renderEncoder.setFragmentSamplerState(pipeline.baseColorSampler, index: 0)

        for item in items {
            for (meshIndex, mesh) in item.mesh.meshes.enumerated() {
                var modelMatrix = item.modelMatrix * item.mesh.localTransforms[meshIndex]
                // Asset node transforms may carry non-uniform scale, so normals
                // use the inverse-transpose rather than the plain upper 3x3.
                let linear = simd_float3x3(modelMatrix.columns.0.xyz,
                                           modelMatrix.columns.1.xyz,
                                           modelMatrix.columns.2.xyz)
                var normalMatrix = linear.inverse.transpose
                renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 2)
                renderEncoder.setVertexBytes(&normalMatrix, length: MemoryLayout<simd_float3x3>.stride, index: 3)

                // The canonical layout interleaves everything into one buffer.
                guard let vertexBuffer = mesh.vertexBuffers.first else { continue }
                renderEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 0)

                let materials = item.mesh.materials.indices.contains(meshIndex)
                    ? item.mesh.materials[meshIndex]
                    : []
                for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
                    let material = materials.indices.contains(submeshIndex)
                        ? materials[submeshIndex]
                        : SceneModelMesh.SubmeshMaterial(baseColorTexture: nil,
                                                         baseColor: SIMD4<Float>(1, 1, 1, 1))
                    var materialUniform = SceneModelMaterialUniform(baseColor: material.baseColor)
                    renderEncoder.setFragmentBytes(&materialUniform,
                                                   length: MemoryLayout<SceneModelMaterialUniform>.stride,
                                                   index: 3)
                    renderEncoder.setFragmentTexture(material.baseColorTexture ?? pipeline.whiteTexture, index: 0)
                    renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                        indexCount: submesh.indexCount,
                                                        indexType: submesh.indexType,
                                                        indexBuffer: submesh.indexBuffer.buffer,
                                                        indexBufferOffset: submesh.indexBuffer.offset)
                }
            }
        }

        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Depth-only replay of the meshes from the light's orthographic cameras
    /// into the two halves of the shadow atlas: no materials, no textures,
    /// cull `.none` (winding does not matter without color output). No encoder
    /// depth bias — the receiver-side bias computed by ShadowFrameStateResolver
    /// covers both caster kinds.
    static func drawShadowCasters(renderEncoder: MTLRenderCommandEncoder,
                                  lightProjectionViews: [matrix_float4x4],
                                  mapResolution: Int,
                                  items: [SceneModelDrawItem],
                                  pipeline: SceneModelPipeline,
                                  extrudedDepthState: MTLDepthStencilState) {
        guard items.isEmpty == false else { return }

        pipeline.selectShadowPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setDepthClipMode(.clamp)

        for (cascadeIndex, lightProjectionView) in lightProjectionViews.enumerated() {
            ShadowCascadeAtlas.selectCascade(renderEncoder: renderEncoder,
                                             cascadeIndex: cascadeIndex,
                                             mapResolution: mapResolution)
            var cameraUniformValue = CameraUniform(matrix: lightProjectionView, eye: .zero, padding: 0)
            renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)

            for item in items {
                for (meshIndex, mesh) in item.mesh.meshes.enumerated() {
                    var modelMatrix = item.modelMatrix * item.mesh.localTransforms[meshIndex]
                    renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 2)

                    guard let vertexBuffer = mesh.vertexBuffers.first else { continue }
                    renderEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 0)

                    for submesh in mesh.submeshes {
                        renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                            indexCount: submesh.indexCount,
                                                            indexType: submesh.indexType,
                                                            indexBuffer: submesh.indexBuffer.buffer,
                                                            indexBufferOffset: submesh.indexBuffer.offset)
                    }
                }
            }
        }

        renderEncoder.setDepthClipMode(.clip)
    }
}
