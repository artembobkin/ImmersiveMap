// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MetalKit
import ModelIO
import simd

enum SceneModelAssetLoadError: Error, Equatable {
    case unsupportedFormat(String)
    case unreadableAsset(URL)
    case meshConversionFailed(URL)
}

/// Synchronous Model I/O loading of a USDZ/OBJ asset into GPU-ready
/// `SceneModelMesh` data. Runs on background tasks owned by `SceneModelMeshStore`.
enum SceneModelAssetLoader {
    /// Canonical interleaved vertex layout shared with `SceneModelPipeline`
    /// and pinned by `SceneModelGPUStructLayoutTests`:
    /// position float3 @0, normal float3 @12, uv float2 @24, stride 32, buffer 0.
    static let vertexStride = 32
    static let normalOffset = 12
    static let uvOffset = 24

    static func makeVertexDescriptor() -> MDLVertexDescriptor {
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                                      format: .float3,
                                                      offset: 0,
                                                      bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal,
                                                      format: .float3,
                                                      offset: normalOffset,
                                                      bufferIndex: 0)
        descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate,
                                                      format: .float2,
                                                      offset: uvOffset,
                                                      bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: vertexStride)
        return descriptor
    }

    static func load(url: URL, device: MTLDevice) throws -> SceneModelMesh {
        guard MDLAsset.canImportFileExtension(url.pathExtension) else {
            throw SceneModelAssetLoadError.unsupportedFormat(url.pathExtension)
        }

        // Load with the source layout first: adding normals to a mesh that
        // lacks them must happen before the canonical re-layout, otherwise the
        // normal attribute would exist but carry undefined data.
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: allocator)
        asset.loadTextures()

        let sourceMeshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard sourceMeshes.isEmpty == false else {
            throw SceneModelAssetLoadError.unreadableAsset(url)
        }

        let canonicalDescriptor = makeVertexDescriptor()
        for mesh in sourceMeshes {
            if mesh.vertexDescriptor.attributeNamed(MDLVertexAttributeNormal) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
            mesh.vertexDescriptor = canonicalDescriptor
        }

        let converted: (modelIOMeshes: [MDLMesh], metalKitMeshes: [MTKMesh])
        do {
            converted = try MTKMesh.newMeshes(asset: asset, device: device)
        } catch {
            throw SceneModelAssetLoadError.meshConversionFailed(url)
        }
        guard converted.metalKitMeshes.isEmpty == false else {
            throw SceneModelAssetLoadError.meshConversionFailed(url)
        }

        let textureLoader = MTKTextureLoader(device: device)
        let localTransforms = converted.modelIOMeshes.map { flattenedNodeTransform(of: $0) }
        let materials = converted.modelIOMeshes.map { mesh in
            ((mesh.submeshes as? [MDLSubmesh]) ?? []).map { submesh in
                makeMaterial(of: submesh, textureLoader: textureLoader)
            }
        }

        return SceneModelMesh(meshes: converted.metalKitMeshes,
                              localTransforms: localTransforms,
                              materials: materials,
                              localBounds: makeBounds(of: asset),
                              costInBytes: costInBytes(meshes: converted.metalKitMeshes,
                                                       materials: materials))
    }

    /// Node transform accumulated up the asset hierarchy: MetalKit conversion
    /// keeps vertices mesh-local, so a mesh placed by USD node transforms must
    /// carry them into the draw.
    private static func flattenedNodeTransform(of mesh: MDLObject) -> matrix_float4x4 {
        var transform = matrix_identity_float4x4
        var object: MDLObject? = mesh
        while let current = object {
            if let localMatrix = current.transform?.matrix {
                transform = localMatrix * transform
            }
            object = current.parent
        }
        return transform
    }

    private static func makeMaterial(of submesh: MDLSubmesh,
                                     textureLoader: MTKTextureLoader) -> SceneModelMesh.SubmeshMaterial {
        let white = SIMD4<Float>(1, 1, 1, 1)
        guard let property = submesh.material?.property(with: .baseColor) else {
            return SceneModelMesh.SubmeshMaterial(baseColorTexture: nil, baseColor: white)
        }

        switch property.type {
        case .texture:
            guard let mdlTexture = property.textureSamplerValue?.texture else {
                return SceneModelMesh.SubmeshMaterial(baseColorTexture: nil, baseColor: white)
            }
            // No sRGB decode: the engine's color pipeline is not color-managed,
            // so textures pass through raw like building style colors do.
            let options: [MTKTextureLoader.Option: Any] = [
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                .generateMipmaps: NSNumber(value: true),
                .SRGB: NSNumber(value: false)
            ]
            let texture = try? textureLoader.newTexture(texture: mdlTexture, options: options)
            return SceneModelMesh.SubmeshMaterial(baseColorTexture: texture, baseColor: white)
        case .float3:
            let color = property.float3Value
            return SceneModelMesh.SubmeshMaterial(baseColorTexture: nil,
                                                  baseColor: SIMD4<Float>(color, 1))
        case .float4:
            return SceneModelMesh.SubmeshMaterial(baseColorTexture: nil,
                                                  baseColor: property.float4Value)
        case .color:
            guard let components = property.color?.components, components.count >= 3 else {
                return SceneModelMesh.SubmeshMaterial(baseColorTexture: nil, baseColor: white)
            }
            let alpha = components.count >= 4 ? Float(components[3]) : 1
            return SceneModelMesh.SubmeshMaterial(baseColorTexture: nil,
                                                  baseColor: SIMD4<Float>(Float(components[0]),
                                                                          Float(components[1]),
                                                                          Float(components[2]),
                                                                          alpha))
        default:
            return SceneModelMesh.SubmeshMaterial(baseColorTexture: nil, baseColor: white)
        }
    }

    private static func makeBounds(of asset: MDLAsset) -> SceneModelMesh.Bounds {
        let boundingBox = asset.boundingBox
        let center = (boundingBox.minBounds + boundingBox.maxBounds) * 0.5
        let extents = boundingBox.maxBounds - boundingBox.minBounds
        let maxExtent = max(extents.x, max(extents.y, extents.z))
        return SceneModelMesh.Bounds(center: center,
                                     radius: max(simd_length(extents) * 0.5, 1e-6),
                                     maxExtent: max(maxExtent, 1e-6))
    }

    private static func costInBytes(meshes: [MTKMesh],
                                    materials: [[SceneModelMesh.SubmeshMaterial]]) -> Int {
        var cost = 0
        for mesh in meshes {
            for vertexBuffer in mesh.vertexBuffers {
                cost += vertexBuffer.length
            }
            for submesh in mesh.submeshes {
                cost += submesh.indexBuffer.length
            }
        }
        for meshMaterials in materials {
            for material in meshMaterials {
                if let texture = material.baseColorTexture {
                    cost += texture.allocatedSize
                }
            }
        }
        return cost
    }
}
