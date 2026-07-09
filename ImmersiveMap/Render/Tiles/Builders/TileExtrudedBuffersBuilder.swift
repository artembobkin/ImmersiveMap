// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

final class TileExtrudedBuffersBuilder {
    private let metalDevice: MTLDevice

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
    }

    func build(extruded: PreparedTileCPU.Extruded) -> TileBuffers.Extruded {
        let vertices = extruded.vertices
        let indices = extruded.indices
        let styles = extruded.styles

        let verticesCount = vertices.count
        let indicesCount = indices.count

        let verticesBuffer: MTLBuffer
        if verticesCount > 0 {
            verticesBuffer = metalDevice.makeBuffer(
                bytes: vertices,
                length: verticesCount * MemoryLayout<TileMvtParser.ExtrudedVertexIn>.stride
            )!
        } else {
            verticesBuffer = metalDevice.makeBuffer(length: 1)!
        }

        let indicesBuffer: MTLBuffer
        if indicesCount > 0 {
            indicesBuffer = metalDevice.makeBuffer(
                bytes: indices,
                length: indicesCount * MemoryLayout<UInt32>.stride
            )!
        } else {
            indicesBuffer = metalDevice.makeBuffer(length: 1)!
        }

        let stylesBuffer: MTLBuffer
        if styles.isEmpty == false {
            stylesBuffer = metalDevice.makeBuffer(
                bytes: styles,
                length: styles.count * MemoryLayout<TilePolygonStyle>.stride
            )!
        } else {
            stylesBuffer = metalDevice.makeBuffer(length: max(1, MemoryLayout<TilePolygonStyle>.stride))!
        }

        return TileBuffers.Extruded(
            verticesBuffer: verticesBuffer,
            indicesBuffer: indicesBuffer,
            stylesBuffer: stylesBuffer,
            indicesCount: indicesCount,
            verticesCount: verticesCount
        )
    }
}
