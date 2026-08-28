// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The fullscreen pass that writes the ground shadow mask: one 8-bit shadow
/// factor per screen pixel, read by every flat ground layer in the world
/// pass (see GroundShadowMask.metal). Single-sample: the mask is a smooth
/// function of the pixel, not geometry with edges, and the MSAA world pass
/// reads it once per pixel.
final class GroundShadowMaskPipeline {
    static let pixelFormat: MTLPixelFormat = .r8Unorm

    let pipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "groundShadowMaskVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "groundShadowMaskFragmentShader")
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
    }

    func select(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
