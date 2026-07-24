// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

final class TileGroundBuffersBuilder {
    private let metalDevice: MTLDevice

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
    }

    func build(layer: PreparedTileCPU.GeometryLayer) -> TileBuffers.GeometryLayer {
        TileBuffers.GeometryLayer(
            verticesBuffer: makeBuffer(layer.vertices),
            indicesBuffer: makeBuffer(layer.indices),
            stylesBuffer: makeBuffer(layer.styles),
            overviewStyleMaskBuffer: makeBuffer(layer.overviewStyleMasks),
            indicesCount: layer.indices.count,
            verticesCount: layer.vertices.count
        )
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        guard values.isEmpty == false else { return nil }
        return metalDevice.makeBuffer(bytes: values,
                                      length: values.count * MemoryLayout<T>.stride)!
    }
}
