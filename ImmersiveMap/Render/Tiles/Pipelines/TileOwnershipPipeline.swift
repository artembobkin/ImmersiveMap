// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The tile-ownership prepass pipeline: vertex-only quads that write the
/// tile-priority stencil before anything else draws in the pass. There is
/// no fragment function and every color attachment's write mask is empty,
/// so the draws touch nothing but the stencil.
final class TileOwnershipPipeline {
    /// The world pass and the offscreen building-image pass (one color
    /// attachment).
    let pipelineState: MTLRenderPipelineState
    /// Pass-compatible twin for the framebuffer-fetch world pass, which
    /// carries the second (building image) color attachment.
    let withBuildingImagePipelineState: MTLRenderPipelineState?

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1,
         supportsFramebufferFetch: Bool = false) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "TileOwnershipPipeline"
        descriptor.vertexFunction = library.makeFunction(name: "tileOwnershipVertexShader")
        descriptor.fragmentFunction = nil
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].writeMask = []
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: descriptor)

        if supportsFramebufferFetch {
            descriptor.colorAttachments[1].pixelFormat = pixelFormat
            descriptor.colorAttachments[1].writeMask = []
            withBuildingImagePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
        } else {
            withBuildingImagePipelineState = nil
        }
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder,
                        withBuildingImageAttachment: Bool) {
        if withBuildingImageAttachment, let withBuildingImagePipelineState {
            renderEncoder.setRenderPipelineState(withBuildingImagePipelineState)
        } else {
            renderEncoder.setRenderPipelineState(pipelineState)
        }
    }
}
