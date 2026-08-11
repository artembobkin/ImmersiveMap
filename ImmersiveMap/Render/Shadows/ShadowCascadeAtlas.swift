// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Layout of the N:1 shadow atlas: cascade `i` rasterizes into the square
/// slot `[i·resolution, (i+1)·resolution) × [0, resolution)`. Shared by the
/// caster drawers, the attachment store and the resolver's UV math so the
/// slots can never disagree with the sampling matrices.
enum ShadowCascadeAtlas {
    /// Near (crisp) / middle / far. Texel world size roughly triples per
    /// step; the middle cascade exists because at a tilted camera most
    /// visible shadows land beyond the near disc, where far-cascade texels
    /// (~11 m) visibly wobble diagonal shadow edges.
    static let cascadeCount = 3

    /// 16 bits are enough: every cascade projection is refit each frame to a
    /// tight caster range with depth clamping, and the receiver bias is
    /// derived from the texel footprint rather than raw depth deltas, so the
    /// extra depth32Float precision bought nothing while doubling atlas
    /// memory and the bandwidth of every `sample_compare` tap. Shared by the
    /// atlas texture, the caster pipelines and the fallback texture so their
    /// formats can never disagree.
    static let depthPixelFormat: MTLPixelFormat = .depth16Unorm

    static func selectCascade(renderEncoder: MTLRenderCommandEncoder,
                              cascadeIndex: Int,
                              mapResolution: Int) {
        let originX = cascadeIndex * mapResolution
        renderEncoder.setViewport(MTLViewport(originX: Double(originX),
                                              originY: 0,
                                              width: Double(mapResolution),
                                              height: Double(mapResolution),
                                              znear: 0,
                                              zfar: 1))
        renderEncoder.setScissorRect(MTLScissorRect(x: originX,
                                                    y: 0,
                                                    width: mapResolution,
                                                    height: mapResolution))
    }
}
