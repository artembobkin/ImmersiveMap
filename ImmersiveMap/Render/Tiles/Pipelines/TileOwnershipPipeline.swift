// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The tile-ownership prepass pipeline: vertex-only quads that write the
/// tile-priority stencil before anything else draws in the pass. There is
/// no fragment function and every color attachment's write mask is empty,
/// so the draws touch nothing but the stencil.
final class TileOwnershipPipeline {
    let pipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "TileOwnershipPipeline"
        descriptor.vertexFunction = library.makeFunction(name: "tileOwnershipVertexShader")
        descriptor.fragmentFunction = nil
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].writeMask = []
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        pipelineState = try! metalDevice.makeArchivedRenderPipelineState(descriptor: descriptor)
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
