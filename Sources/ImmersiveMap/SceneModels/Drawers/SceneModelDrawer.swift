// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit
import simd

/// One culled, anchor-resolved model ready to encode.
struct SceneModelDrawItem {
    let mesh: SceneModelMesh
    let modelMatrix: matrix_float4x4
    let groundPlane: SceneModelGroundPlane
    /// See `ImmersiveMapSceneModel.cutsIntoGround`.
    let cutsIntoGround: Bool
}

/// The depth and stencil states of the ground cut's four draws
/// (SceneModel.metal), built by SharedRenderResources around
/// `TileSourceStencilPriority.groundHoleBit`.
struct SceneModelGroundCutStates {
    /// The flattened footprint raising the hole bit: depth neither tested
    /// nor written.
    let holeWrite: MTLDepthStencilState
    /// The flattened footprint lowering the hole bit again.
    let holeClear: MTLDepthStencilState
    /// The model's two draws: scene depth, the surface mask bit raised
    /// where the model lands, and the hole bit tested equal to the
    /// reference's, raised for the draw inside the hole and clear for the
    /// draw outside it.
    let holeTest: MTLDepthStencilState
}

enum SceneModelDrawer {
    /// Swift mirror of `SceneModelMaterial` in SceneModel.metal.
    struct SceneModelMaterialUniform {
        var baseColor: SIMD4<Float>
    }

    /// Opaque model geometry with depth test and depth write in the world
    /// pass, raising the surface mask bit where it lands so the horizon's
    /// haze passes it by. A model that cuts into the ground takes the four
    /// draws of the ground cut instead (SceneModel.metal).
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     shadowBinding: ShadowReceiverBinding,
                     items: [SceneModelDrawItem],
                     pipeline: SceneModelPipeline,
                     surfaceMaskState: MTLDepthStencilState,
                     groundCutStates: SceneModelGroundCutStates,
                     depthDisabledState: MTLDepthStencilState) {
        guard items.isEmpty == false else { return }

        var cameraUniformValue = cameraUniform
        renderEncoder.setCullMode(.back)
        // Model I/O meshes are counterclockwise-wound; Metal defaults to clockwise.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)

        var shadowUniformValue = shadowBinding.uniform
        renderEncoder.setFragmentBytes(&shadowUniformValue, length: MemoryLayout<ShadowUniform>.stride, index: 4)
        renderEncoder.setFragmentTexture(shadowBinding.texture, index: 1)
        renderEncoder.setFragmentSamplerState(pipeline.baseColorSampler, index: 0)

        for item in items {
            var groundPlane = item.groundPlane
            renderEncoder.setVertexBytes(&groundPlane, length: MemoryLayout<SceneModelGroundPlane>.stride, index: 4)

            if item.cutsIntoGround {
                // The hole: the outline on the ground, raised, and the
                // stencil reference carries the bit the inside draw tests
                // for and the surface mask bit both draws raise.
                pipeline.selectGroundFootprintPipeline(renderEncoder: renderEncoder)
                renderEncoder.setCullMode(.none)
                renderEncoder.setDepthStencilState(groundCutStates.holeWrite)
                renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.groundHoleBit)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: false)
                renderEncoder.setCullMode(.back)

                pipeline.selectPipeline(renderEncoder: renderEncoder)
                renderEncoder.setDepthStencilState(groundCutStates.holeTest)
                renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.groundHoleBit
                                                       | TileSourceStencilPriority.surfaceMaskBit)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: true)

                pipeline.selectBelowGroundClippedPipeline(renderEncoder: renderEncoder)
                renderEncoder.setDepthStencilState(groundCutStates.holeTest)
                renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.surfaceMaskBit)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: true)

                pipeline.selectGroundFootprintPipeline(renderEncoder: renderEncoder)
                renderEncoder.setCullMode(.none)
                renderEncoder.setDepthStencilState(groundCutStates.holeClear)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: false)
                renderEncoder.setCullMode(.back)
            } else {
                pipeline.selectPipeline(renderEncoder: renderEncoder)
                renderEncoder.setDepthStencilState(surfaceMaskState)
                renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.surfaceMaskBit)
                encodeMeshes(renderEncoder: renderEncoder, item: item, pipeline: pipeline, withMaterials: true)
            }
        }

        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Every submesh of the item under the pipeline and state already set.
    /// The materials are bound for the colour pipelines and skipped for the
    /// footprint pipeline, which has no fragment function.
    private static func encodeMeshes(renderEncoder: MTLRenderCommandEncoder,
                                     item: SceneModelDrawItem,
                                     pipeline: SceneModelPipeline,
                                     withMaterials: Bool) {
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
                if withMaterials {
                    let material = materials.indices.contains(submeshIndex)
                        ? materials[submeshIndex]
                        : SceneModelMesh.SubmeshMaterial(baseColorTexture: nil,
                                                         baseColor: SIMD4<Float>(1, 1, 1, 1))
                    var materialUniform = SceneModelMaterialUniform(baseColor: material.baseColor)
                    renderEncoder.setFragmentBytes(&materialUniform,
                                                   length: MemoryLayout<SceneModelMaterialUniform>.stride,
                                                   index: 3)
                    renderEncoder.setFragmentTexture(material.baseColorTexture ?? pipeline.whiteTexture, index: 0)
                }
                renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                    indexCount: submesh.indexCount,
                                                    indexType: submesh.indexType,
                                                    indexBuffer: submesh.indexBuffer.buffer,
                                                    indexBufferOffset: submesh.indexBuffer.offset)
            }
        }
    }

    /// Depth-only replay of the meshes from the light's orthographic camera,
    /// one draw per submesh (one window, so nothing to instance over).
    /// No materials, no textures,
    /// cull `.none` (winding does not matter without color output). No encoder
    /// depth bias, the receiver-side bias computed by ShadowFrameStateResolver
    /// covers both caster kinds.
    static func drawShadowCasters(renderEncoder: MTLRenderCommandEncoder,
                                  lightProjectionView: matrix_float4x4,
                                  items: [SceneModelDrawItem],
                                  pipeline: SceneModelPipeline,
                                  extrudedDepthState: MTLDepthStencilState) {
        guard items.isEmpty == false else { return }

        pipeline.selectShadowPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setDepthClipMode(.clamp)

        var castersValue = ShadowCasterUniform(lightProjectionView: lightProjectionView)
        renderEncoder.setVertexBytes(&castersValue, length: MemoryLayout<ShadowCasterUniform>.stride, index: 1)

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

        renderEncoder.setDepthClipMode(.clip)
    }
}
