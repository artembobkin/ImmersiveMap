// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Frozen per-frame shadow state resolved in `collectInput`: the two cascade
/// light cameras for the caster pass and the sampling uniform for every
/// receiver. `nil` on `FrameContext` means "no shadows this frame" (globe
/// mode, disabled, or a degenerate light).
struct ShadowFrameState {
    /// World → clip matrices of the directional light's orthographic cameras,
    /// `[near, far]`. The far cascade's volume is a superset of the near one,
    /// so caster culling only needs the last entry.
    let lightProjectionViews: [matrix_float4x4]
    let shadowUniform: ShadowUniform
    /// Square side of ONE cascade half in pixels; the atlas texture is
    /// `2 * mapResolution` wide and `mapResolution` tall.
    let mapResolution: Int
}
