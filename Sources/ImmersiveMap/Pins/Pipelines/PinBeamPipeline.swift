// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit

/// Pipeline for the beam cone from the geo point to the displaced circle;
/// drawn in the overlay pass before the pin bubbles.
final class PinBeamPipeline {
    let beamPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        self.beamPipelineState = Self.makePipelineState(metalDevice: metalDevice,
                                                        pixelFormat: pixelFormat,
                                                        library: library,
                                                        sampleCount: sampleCount,
                                                        vertexFunctionName: "pinBeamVertex",
                                                        fragmentFunctionName: "pinBeamFragment")
    }

    func selectBeamPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(beamPipelineState)
    }

    private static func makePipelineState(metalDevice: MTLDevice,
                                          pixelFormat: MTLPixelFormat,
                                          library: MTLLibrary,
                                          sampleCount: Int,
                                          vertexFunctionName: String,
                                          fragmentFunctionName: String) -> MTLRenderPipelineState {
        let vertexFunction = library.makeFunction(name: vertexFunctionName)
        let fragmentFunction = library.makeFunction(name: fragmentFunctionName)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .mapDepthStencil
        pipelineDescriptor.stencilAttachmentPixelFormat = .mapDepthStencil
        pipelineDescriptor.colorAttachments[0].setAlphaBlending()

        return try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
}
