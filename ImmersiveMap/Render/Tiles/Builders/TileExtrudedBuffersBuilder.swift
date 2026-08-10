// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

final class TileExtrudedBuffersBuilder {
    private let metalDevice: MTLDevice

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
    }

    func build(extruded: PreparedTileCPU.Extruded) -> TileBuffers.Extruded {
        let indicesBuffer: MTLBuffer?
        let indexType: MTLIndexType
        if let narrowedIndices = IndexStorageMath.narrowedIndices(extruded.indices,
                                                                  vertexCount: extruded.vertices.count) {
            indicesBuffer = makeBuffer(narrowedIndices)
            indexType = .uint16
        } else {
            indicesBuffer = makeBuffer(extruded.indices)
            indexType = .uint32
        }
        return TileBuffers.Extruded(
            verticesBuffer: makeBuffer(extruded.vertices),
            indicesBuffer: indicesBuffer,
            stylesBuffer: makeBuffer(extruded.styles),
            indicesCount: extruded.indices.count,
            verticesCount: extruded.vertices.count,
            indexType: indexType
        )
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        guard values.isEmpty == false else { return nil }
        return metalDevice.makeBuffer(bytes: values,
                                      length: values.count * MemoryLayout<T>.stride)!
    }
}
