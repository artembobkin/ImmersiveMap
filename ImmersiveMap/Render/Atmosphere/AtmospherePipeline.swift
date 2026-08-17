// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The fullscreen pass that paints the atmosphere halo in space around the
/// globe. One pipeline state, shared by every renderer in the process.
final class AtmospherePipeline {
    let pipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "AtmospherePipeline"
        descriptor.vertexFunction = library.makeFunction(name: "atmosphereVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "atmosphereFragmentShader")
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float
        // Premultiplied "over": the shader hands out the halo tint already
        // weighted by its coverage, and the coverage in alpha, so the halo
        // covers space at the limb and thins to nothing with distance. Alpha
        // composes the same way, which keeps the frame's own coverage right
        // where space is transparent.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create atmosphere pipeline: \(error)")
        }
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
