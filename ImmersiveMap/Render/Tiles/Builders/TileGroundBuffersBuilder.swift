// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

final class TileGroundBuffersBuilder {
    private let metalDevice: MTLDevice

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
    }

    func build(layer: PreparedTileCPU.GeometryLayer) -> TileBuffers.GeometryLayer {
        let indicesBuffer: MTLBuffer?
        let indexType: MTLIndexType
        if let narrowedIndices = IndexStorageMath.narrowedIndices(layer.indices,
                                                                  vertexCount: layer.vertices.count) {
            indicesBuffer = makeBuffer(narrowedIndices)
            indexType = .uint16
        } else {
            indicesBuffer = makeBuffer(layer.indices)
            indexType = .uint32
        }
        return TileBuffers.GeometryLayer(
            verticesBuffer: makeBuffer(layer.vertices),
            indicesBuffer: indicesBuffer,
            stylesBuffer: makeBuffer(layer.styles),
            overviewStyleMaskBuffer: makeBuffer(layer.overviewStyleMasks),
            indicesCount: layer.indices.count,
            verticesCount: layer.vertices.count,
            indexType: indexType
        )
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        guard values.isEmpty == false else { return nil }
        return metalDevice.makeBuffer(bytes: values,
                                      length: values.count * MemoryLayout<T>.stride)!
    }
}
