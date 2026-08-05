// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// One route resolved into a draw call: where its centerline points start in
/// the shared frame buffer, how many there are, and the style uniform.
struct RouteDrawItem {
    let pointBufferOffsetElements: Int
    let pointCount: Int
    let uniform: RouteUniformGPU
}

enum RouteDrawer {
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     items: [RouteDrawItem],
                     pointsBuffer: MTLBuffer,
                     cameraUniform: CameraUniform,
                     pipeline: RoutePipeline) {
        guard items.isEmpty == false else { return }

        pipeline.selectPipeline(renderEncoder: renderEncoder)
        // A triangle strip built from alternating sides alternates winding, and
        // the scene model layer just before this one culls back faces.
        renderEncoder.setCullMode(.none)

        var camera = cameraUniform
        renderEncoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 1)

        let stride = MemoryLayout<RouteWorldGeometryBuilder.Point>.stride
        for item in items {
            var uniform = item.uniform
            renderEncoder.setVertexBuffer(pointsBuffer,
                                          offset: item.pointBufferOffsetElements * stride,
                                          index: 0)
            renderEncoder.setVertexBytes(&uniform, length: MemoryLayout<RouteUniformGPU>.stride, index: 2)
            renderEncoder.setFragmentBytes(&uniform, length: MemoryLayout<RouteUniformGPU>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip,
                                         vertexStart: 0,
                                         vertexCount: item.pointCount * 2)
        }
    }
}
