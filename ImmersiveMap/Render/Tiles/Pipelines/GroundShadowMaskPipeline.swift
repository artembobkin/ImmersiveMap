// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Metal

/// The fullscreen pass that writes the ground shadow mask: one 8-bit shadow
/// factor per screen pixel, read by every flat ground layer in the world
/// pass (see GroundShadowMask.metal). Single-sample: the mask is a smooth
/// function of the pixel, not geometry with edges, and the MSAA world pass
/// reads it once per pixel.
final class GroundShadowMaskPipeline {
    static let pixelFormat: MTLPixelFormat = .r8Unorm
    /// Mask pixels per drawable pixel. Half resolution: the shadow edge is
    /// already a two-texel ramp of a cascade whose texel spans several
    /// screen pixels at street zoom, so a bilinear upsample of a half-size
    /// mask is indistinguishable from a full-size one and the pass costs a
    /// quarter of the fragments. Mirrored by `kGroundShadowMaskScale` in
    /// Tile.metal, where the ground turns its pixel position into mask UV.
    static let resolutionScale: CGFloat = 0.5

    /// The mask size for a drawable, rounded up so the mask always covers it.
    static func maskSize(for drawSize: CGSize) -> CGSize {
        CGSize(width: (drawSize.width * resolutionScale).rounded(.up),
               height: (drawSize.height * resolutionScale).rounded(.up))
    }

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
