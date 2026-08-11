// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Frozen per-frame shadow state resolved in `collectInput`: the cascade
/// light cameras for the caster pass and the sampling uniform for every
/// receiver. `nil` on `FrameContext` means "no shadows this frame" (globe
/// mode, disabled, or a degenerate light).
struct ShadowFrameState {
    /// World → clip matrices of the directional light's orthographic cameras,
    /// `[near, middle, far]`. The far cascade's volume is a superset of the
    /// nearer ones, so caster culling only needs the last entry.
    let lightProjectionViews: [matrix_float4x4]
    let shadowUniform: ShadowUniform
    /// Square side of ONE cascade slice in pixels; the shadow texture is an
    /// array of `ShadowCascadeAtlas.cascadeCount` such slices.
    let mapResolution: Int
}
