// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame input of the ground shadow mask pass; the layout mirrors
/// `GroundShadowMaskUniform` in GroundShadowMask.metal (pinned by
/// `ShadowUniformLayoutTests`).
///
/// The pass reconstructs the ground-plane point under every pixel from the
/// inverse projection-view and samples the cascades there once, so the
/// blended ground layers can read one value instead of each sampling the
/// cascades again for the same pixel.
struct GroundShadowMaskUniform {
    var inverseProjectionView: matrix_float4x4
    /// Mask size in pixels, equal to the drawable size.
    var viewportSize: SIMD2<Float>
    var _padding: SIMD2<Float> = .zero

    init(projectionView: matrix_float4x4, viewportSize: SIMD2<Float>) {
        self.inverseProjectionView = simd_inverse(projectionView)
        self.viewportSize = viewportSize
    }
}
