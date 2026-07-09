// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class MetalTerrainMesh {
    let tile: Tile
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let estimatedMemoryCost: Int

    init?(device: MTLDevice, mesh: TerrainMesh) {
        guard mesh.vertices.isEmpty == false,
              mesh.indices.isEmpty == false,
              let vertexBuffer = device.makeBuffer(bytes: mesh.vertices,
                                                   length: MemoryLayout<TerrainMesh.Vertex>.stride * mesh.vertices.count),
              let indexBuffer = device.makeBuffer(bytes: mesh.indices,
                                                  length: MemoryLayout<UInt32>.stride * mesh.indices.count) else {
            return nil
        }

        self.tile = mesh.tile
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = mesh.indices.count
        self.estimatedMemoryCost = vertexBuffer.length + indexBuffer.length
    }
}
