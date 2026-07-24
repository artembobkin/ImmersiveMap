// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

final class TileExtrudedBuffersBuilder {
    private let metalDevice: MTLDevice

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
    }

    func build(extruded: PreparedTileCPU.Extruded) -> TileBuffers.Extruded {
        TileBuffers.Extruded(
            verticesBuffer: makeBuffer(extruded.vertices),
            indicesBuffer: makeBuffer(extruded.indices),
            stylesBuffer: makeBuffer(extruded.styles),
            indicesCount: extruded.indices.count,
            verticesCount: extruded.vertices.count
        )
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        guard values.isEmpty == false else { return nil }
        return metalDevice.makeBuffer(bytes: values,
                                      length: values.count * MemoryLayout<T>.stride)!
    }
}
