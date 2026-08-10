// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// GPU buffers of the map surface grid: vertices, indices, the index count and
/// the index type for an indexed draw.
struct MapSurfaceGridBuffers {
    let verticesBuffer: MTLBuffer
    let indicesBuffer: MTLBuffer
    let indicesCount: Int
    let indexType: MTLIndexType

    /// Builds the GPU buffers for a static grid, narrowing the indices to 16
    /// bits when the vertex count allows it.
    static func make<Vertex>(metalDevice: MTLDevice,
                             vertices: [Vertex],
                             indices: [UInt32]) -> MapSurfaceGridBuffers {
        let verticesBuffer = metalDevice.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count
        )!
        if let narrowedIndices = IndexStorageMath.narrowedIndices(indices, vertexCount: vertices.count) {
            return MapSurfaceGridBuffers(
                verticesBuffer: verticesBuffer,
                indicesBuffer: metalDevice.makeBuffer(
                    bytes: narrowedIndices,
                    length: MemoryLayout<UInt16>.stride * narrowedIndices.count
                )!,
                indicesCount: narrowedIndices.count,
                indexType: .uint16
            )
        }
        return MapSurfaceGridBuffers(
            verticesBuffer: verticesBuffer,
            indicesBuffer: metalDevice.makeBuffer(
                bytes: indices,
                length: MemoryLayout<UInt32>.stride * indices.count
            )!,
            indicesCount: indices.count,
            indexType: .uint32
        )
    }
}
