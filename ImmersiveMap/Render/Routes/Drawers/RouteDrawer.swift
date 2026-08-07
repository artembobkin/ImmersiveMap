// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// One route resolved into a draw call: where its centerline points start in
/// the shared frame buffer, how many there are, and the style uniform.
struct RouteDrawItem {
    let pointBufferOffsetElements: Int
    let screenLengthBufferOffsetElements: Int
    let pointCount: Int
    let uniform: RouteUniformGPU
}

enum RouteDrawer {
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     items: [RouteDrawItem],
                     pointsBuffer: MTLBuffer,
                     screenLengthsBuffer: MTLBuffer,
                     cameraUniform: CameraUniform,
                     globeUniform: GlobeUniform,
                     pipeline: RoutePipeline) {
        guard items.isEmpty == false else { return }

        pipeline.selectPipeline(renderEncoder: renderEncoder)
        // A triangle strip built from alternating sides alternates winding, and
        // the scene model layer just before this one culls back faces.
        renderEncoder.setCullMode(.none)

        var camera = cameraUniform
        renderEncoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 1)
        // The sphere the shader tests the centerline against: routes are hidden
        // by the globe body itself, not by what happens to be in the depth
        // buffer. The fragment stage runs the occlusion test, the vertex stage
        // only needs the radius for the unfurl release.
        var globe = globeUniform
        renderEncoder.setVertexBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 4)
        renderEncoder.setFragmentBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 2)

        let pointStride = MemoryLayout<RouteWorldGeometryBuilder.Point>.stride
        let screenLengthStride = MemoryLayout<Float>.stride
        for item in items {
            var uniform = item.uniform
            renderEncoder.setVertexBuffer(pointsBuffer,
                                          offset: item.pointBufferOffsetElements * pointStride,
                                          index: 0)
            renderEncoder.setVertexBuffer(screenLengthsBuffer,
                                          offset: item.screenLengthBufferOffsetElements * screenLengthStride,
                                          index: 3)
            renderEncoder.setVertexBytes(&uniform, length: MemoryLayout<RouteUniformGPU>.stride, index: 2)
            renderEncoder.setFragmentBytes(&uniform, length: MemoryLayout<RouteUniformGPU>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip,
                                         vertexStart: 0,
                                         vertexCount: item.pointCount * 2)
        }
    }
}
