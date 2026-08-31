// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The deferred globe-surface lighting pass: one fullscreen triangle whose
/// fragment outputs the additive light in rgb and the brightness in alpha,
/// with the blend state doing the actual lighting arithmetic per sample:
/// `color = dst.rgb * src.a + src.rgb`, alpha left untouched. One pipeline
/// state, shared by every renderer in the process.
final class GlobeSurfaceLightingPipeline {
    let pipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GlobeSurfaceLightingPipeline"
        descriptor.vertexFunction = library.makeFunction(name: "globeSurfaceLightingVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "globeSurfaceLightingFragmentShader")
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float
        // The light is affine in the surface colour: multiply by the
        // brightness the fragment hands out in alpha, add the rim and glow
        // it hands out in rgb. The destination alpha is the frame's own
        // coverage and stays exactly as the layers left it.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        do {
            pipelineState = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create the globe surface lighting pipeline: \(error)")
        }
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
