// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Frozen per-frame shadow state resolved in `collectInput`: the light camera
/// for the caster pass and the sampling uniform for every receiver. `nil` on
/// `FrameContext` means "no shadows this frame" (globe mode, disabled, or a
/// degenerate light).
struct ShadowFrameState {
    /// World → clip matrix of the directional light's orthographic camera.
    let lightProjectionView: matrix_float4x4
    let shadowUniform: ShadowUniform
    /// Square side of the shadow map in pixels.
    let mapResolution: Int
}
