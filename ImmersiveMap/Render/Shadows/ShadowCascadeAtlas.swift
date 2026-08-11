// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Layout of the shadow texture array: cascade `i` rasterizes into slice `i`,
/// routed there by `[[render_target_array_index]]` in the caster vertex
/// stages. Shared by the caster drawers, the attachment store and the
/// resolver's UV math so the slices can never disagree with the sampling
/// matrices.
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
}
