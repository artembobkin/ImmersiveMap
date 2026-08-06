// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit

/// Pipeline for the beam cone from the geo point to the displaced circle;
/// drawn in the overlay pass before the avatar bubbles.
final class AvatarBeamPipeline {
    let beamPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        self.beamPipelineState = Self.makePipelineState(metalDevice: metalDevice,
                                                        pixelFormat: pixelFormat,
                                                        library: library,
                                                        sampleCount: sampleCount,
                                                        vertexFunctionName: "avatarBeamVertex",
                                                        fragmentFunctionName: "avatarBeamFragment")
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

        return try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
}
