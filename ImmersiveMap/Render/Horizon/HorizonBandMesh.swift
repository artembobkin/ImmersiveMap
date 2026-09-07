// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The static geometry of the globe's atmosphere band: a grid of azimuths
/// about the eye's local vertical by stations either side of the limb
/// (`HorizonBandMath`), built once per process. Every vertex is only the
/// pair `(azimuth, station)`; the vertex shader turns it into a direction
/// from the frame's edge, so nothing here changes per frame.
struct HorizonBandMesh {
    /// Mirrors `HorizonBandVertexIn` in Horizon.metal.
    struct Vertex {
        var azimuth: Float
        var station: Float
    }

    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    init?(metalDevice: MTLDevice) {
        let segments = HorizonBandMath.segmentCount
        let stations = HorizonBandMath.stationCount
        var vertices: [Vertex] = []
        vertices.reserveCapacity(segments * stations)
        for segment in 0 ..< segments {
            let azimuth = Float(segment) / Float(segments) * 2 * .pi
            for station in 0 ..< stations {
                vertices.append(Vertex(azimuth: azimuth, station: Float(station)))
            }
        }
        var indices: [UInt16] = []
        indices.reserveCapacity(segments * (stations - 1) * 6)
        for segment in 0 ..< segments {
            let next = (segment + 1) % segments
            for station in 0 ..< (stations - 1) {
                let a = UInt16(segment * stations + station)
                let b = UInt16(next * stations + station)
                let c = UInt16(next * stations + station + 1)
                let d = UInt16(segment * stations + station + 1)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        guard let vertexBuffer = metalDevice.makeBuffer(bytes: vertices,
                                                        length: vertices.count * MemoryLayout<Vertex>.stride,
                                                        options: .storageModeShared),
              let indexBuffer = metalDevice.makeBuffer(bytes: indices,
                                                       length: indices.count * MemoryLayout<UInt16>.stride,
                                                       options: .storageModeShared) else {
            return nil
        }
        vertexBuffer.label = "HorizonBandVertices"
        indexBuffer.label = "HorizonBandIndices"
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
    }
}
