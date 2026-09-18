// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The rasterized tile pipeline (TileRaster.metal): one textured quad per
/// rasterized source in the flat world pass, opaque, writing the ground's
/// rank depth from the fragment stage and owning the tile-priority stencil
/// through the ground owner state.
final class TileRasterPipeline {
    let pipelineState: MTLRenderPipelineState

    /// - Parameter readsGroundShadowMask: the flat world pass binds the
    ///   per-pixel ground shadow mask at fragment texture 1 (see
    ///   `TilePipeline`).
    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1,
         readsGroundShadowMask: Bool = false) {
        let values = MTLFunctionConstantValues()
        var readsMask = readsGroundShadowMask
        values.setConstantValue(&readsMask, type: .bool, index: 0)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "TileRasterPipeline"
        descriptor.vertexFunction = try! library.makeFunction(name: "tileRasterVertexShader", constantValues: values)
        descriptor.fragmentFunction = try! library.makeFunction(name: "tileRasterFragmentShader", constantValues: values)
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
