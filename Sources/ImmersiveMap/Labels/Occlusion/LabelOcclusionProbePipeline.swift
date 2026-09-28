// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The point-label occlusion probes of the world pass (see
/// `LabelOcclusionProbe`): one point per label, depth-tested against the
/// buildings and the models the pass drew before it, every color channel
/// masked, the depth never written. The fragment marks the labels whose
/// probe passed in a buffer the CPU reads back a few frames later.
final class LabelOcclusionProbePipeline {
    let pipelineState: MTLRenderPipelineState
    /// Strictly nearer than the scene passes, nothing is written, and the
    /// tile-priority stencil is ignored: a probe belongs to no tile.
    let depthState: MTLDepthStencilState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "LabelOcclusionProbePipeline"
        descriptor.vertexFunction = library.makeFunction(name: "labelOcclusionProbeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "labelOcclusionProbeFragment")
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].writeMask = []
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = false
        depthState = metalDevice.makeDepthStencilState(descriptor: depthDescriptor)!
    }
}
