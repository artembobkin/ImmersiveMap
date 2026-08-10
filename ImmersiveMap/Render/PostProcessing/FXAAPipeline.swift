// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Metal
import QuartzCore

final class FXAAPipeline {
    private struct Uniform {
        var inverseViewportSize: SIMD2<Float>
    }

    private let pipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "postProcessingVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "fxaaFragmentShader")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              sourceTexture: MTLTexture,
              drawSize: CGSize) {
        let width = max(Float(drawSize.width), 1.0)
        let height = max(Float(drawSize.height), 1.0)
        var uniform = Uniform(inverseViewportSize: SIMD2<Float>(1.0 / width, 1.0 / height))

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(sourceTexture, index: 0)
        renderEncoder.setFragmentBytes(&uniform,
                                       length: MemoryLayout<Uniform>.stride,
                                       index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
