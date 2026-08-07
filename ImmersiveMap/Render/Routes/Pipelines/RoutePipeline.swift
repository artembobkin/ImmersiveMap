// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// GPU mirror of `RouteUniform` in Route.metal. Size and stride are 48 bytes on
/// both sides; `RouteGPUStructLayoutTests` pins the offsets. The globe the
/// shader tests the centerline against arrives separately, as the same
/// `GlobeUniform` the surface layers bind.
struct RouteUniformGPU {
    var viewport: SIMD2<Float>
    var halfWidthPx: Float
    var sampleCount: UInt32
    var color: SIMD4<Float>
    /// Drawn part of one dash period, in drawable pixels; zero draws solid.
    var dashPx: Float
    var gapPx: Float
    var padding: SIMD2<Float> = .zero
}

/// World-pass pipeline for route ribbons: alpha blended for antialiased edges,
/// no vertex descriptor because the shader addresses samples by vertex id.
final class RoutePipeline {
    let pipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "routeVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "routeFragmentShader")
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        // Alpha blends with .one so coverage accumulates on a transparent
        // destination; over an opaque one the result is unchanged.
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
