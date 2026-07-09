// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

final class TileGroundBuffersBuilder {
    private let metalDevice: MTLDevice

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
    }

    func build(layer: PreparedTileCPU.GeometryLayer) -> TileBuffers.GeometryLayer {
        let verticesBuffer: MTLBuffer
        if layer.vertices.isEmpty {
            verticesBuffer = metalDevice.makeBuffer(length: 1)!
        } else {
            verticesBuffer = metalDevice.makeBuffer(
                bytes: layer.vertices,
                length: layer.vertices.count * MemoryLayout<TilePipeline.VertexIn>.stride
            )!
        }

        let indicesBuffer: MTLBuffer
        if layer.indices.isEmpty {
            indicesBuffer = metalDevice.makeBuffer(length: 1)!
        } else {
            indicesBuffer = metalDevice.makeBuffer(
                bytes: layer.indices,
                length: layer.indices.count * MemoryLayout<UInt32>.stride
            )!
        }

        let stylesBuffer: MTLBuffer
        if layer.styles.isEmpty {
            stylesBuffer = metalDevice.makeBuffer(length: 1)!
        } else {
            stylesBuffer = metalDevice.makeBuffer(
                bytes: layer.styles,
                length: layer.styles.count * MemoryLayout<TilePolygonStyle>.stride
            )!
        }

        let overviewStyleMaskBuffer: MTLBuffer
        if layer.overviewStyleMasks.isEmpty {
            overviewStyleMaskBuffer = metalDevice.makeBuffer(length: MemoryLayout<Float>.stride)!
        } else {
            overviewStyleMaskBuffer = metalDevice.makeBuffer(bytes: layer.overviewStyleMasks,
                                                             length: layer.overviewStyleMasks.count * MemoryLayout<Float>.stride)!
        }

        return TileBuffers.GeometryLayer(
            verticesBuffer: verticesBuffer,
            indicesBuffer: indicesBuffer,
            stylesBuffer: stylesBuffer,
            overviewStyleMaskBuffer: overviewStyleMaskBuffer,
            indicesCount: layer.indices.count,
            verticesCount: layer.vertices.count
        )
    }
}
