// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

extension MTLPixelFormat {
    /// The format of the frame's depth and stencil, which every pipeline
    /// that draws into the world or the overlay pass is built for.
    static let mapDepthStencil: MTLPixelFormat = .depth32Float_stencil8
}

extension MTLRenderPipelineColorAttachmentDescriptor {
    /// The blend the map's translucent draws share: the colour over what
    /// is there by the source's alpha. The alpha itself blends with `.one`,
    /// so coverage accumulates on a transparent destination (an export
    /// with no background, a frame with transparent space). Over an opaque
    /// one the result is unchanged.
    func setAlphaBlending() {
        isBlendingEnabled = true
        rgbBlendOperation = .add
        alphaBlendOperation = .add
        sourceRGBBlendFactor = .sourceAlpha
        sourceAlphaBlendFactor = .one
        destinationRGBBlendFactor = .oneMinusSourceAlpha
        destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
}
