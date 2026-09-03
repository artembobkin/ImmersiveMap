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
    /// Per-cascade receiver-plane depth gradient of the ground plane
    /// (dz/du, dz/dv in the cascade's slice space), computed analytically:
    /// the plane is z = 0 and every cascade projection is affine, so the
    /// gradient is one constant per cascade per frame. It replaces the
    /// screen-space derivatives the mask shader used to take, which frees
    /// its control flow to exit early above the horizon and beyond the
    /// shadow fade. Clamped exactly like `shadowAnalyticGradient`.
    var planeGradientNear: SIMD2<Float>
    var planeGradientMiddle: SIMD2<Float>
    var planeGradientFar: SIMD2<Float>
    var _padding1: SIMD2<Float> = .zero

    init(projectionView: matrix_float4x4, viewportSize: SIMD2<Float>, shadow: ShadowUniform) {
        self.inverseProjectionView = simd_inverse(projectionView)
        self.viewportSize = viewportSize
        self.planeGradientNear = Self.groundPlaneGradient(cascade: shadow.cascadeNear)
        self.planeGradientMiddle = Self.groundPlaneGradient(cascade: shadow.cascadeMiddle)
        self.planeGradientFar = Self.groundPlaneGradient(cascade: shadow.cascadeFar)
    }

    /// dz/d(u,v) of the ground plane in one cascade's slice space: solve the
    /// 2x2 world→uv Jacobian restricted to the plane (the same solve as the
    /// shader's `shadowAnalyticGradient`, evaluated once on the CPU because
    /// the ground plane is the same for every mask pixel).
    static func groundPlaneGradient(cascade: ShadowCascadeUniform) -> SIMD2<Float> {
        let m = cascade.worldToShadowTexture
        // Column-major: m[column][row]. u/v/z as functions of world x/y on
        // the plane z = 0.
        let dudx = m[0][0], dudy = m[1][0]
        let dvdx = m[0][1], dvdy = m[1][1]
        let dzdx = m[0][2], dzdy = m[1][2]
        let det = dudx * dvdy - dudy * dvdx
        guard abs(det) > 1e-12 else { return .zero }
        let dzdu = (dvdy * dzdx - dvdx * dzdy) / det
        let dzdv = (dudx * dzdy - dudy * dzdx) / det
        let aspect = cascade.texelSizeUV.x / max(cascade.texelSizeUV.y, 1e-9)
        let axisClamp = cascade.gradientClamp * SIMD2<Float>(1.0, aspect)
        return simd_clamp(SIMD2<Float>(dzdu, dzdv), -axisClamp, axisClamp)
    }
}
