// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The shadow window's sampling parameters; the layout mirrors
/// `ShadowCascade` in RenderUniforms.h (pinned by `ShadowUniformLayoutTests`).
///
/// `worldToShadowTexture` maps flat world space straight to the shadow map:
/// xy is the texture UV (v flipped for Metal's top-left origin), z the
/// comparison depth.
struct ShadowCascadeUniform {
    var worldToShadowTexture: matrix_float4x4
    /// Softness of the shadow's edge: the factor the tent's four taps are
    /// pushed out by, about the sample point (`ShadowSettings.softness`,
    /// clamped to `ShadowFrameStateResolver.softnessRange`). 1 is the plain
    /// 3x3 tent. The kernel stays symmetric about the sample point, so a
    /// wider spread lengthens the ramp without moving the shadow's edge.
    var tentSpread: Float
    var _padding2: Float = 0
    /// Receiver-side comparison bias in normalized shadow depth.
    var depthBias: Float
    var _padding1: Float = 0
    /// Valid UV rectangle, inset so the tent's taps never leave the fitted
    /// window, at the widest spread `softnessRange` allows.
    var uvMinimum: SIMD2<Float>
    var uvMaximum: SIMD2<Float>
    /// World-space distance receivers with normals shift their sample point
    /// along the surface normal: the receiver leaves its own surface towards
    /// the light, so self-comparison cannot stripe even where the wall's map
    /// footprint is sub-texel, while occluders farther away than the offset
    /// still shadow it. Always `normalOffsetTexels` texels of this window,
    /// which is itself sized to the camera distance, so the offset is a fixed
    /// fraction of that distance and a roughly constant size on screen.
    var normalOffsetWorld: Float
    var _padding0: Float = 0
    /// One texel of the window in UV; the tent's offsets go through it.
    var texelSizeUV: SIMD2<Float>

    static let disabled = ShadowCascadeUniform(worldToShadowTexture: matrix_identity_float4x4,
                                               tentSpread: 1,
                                               depthBias: 0,
                                               uvMinimum: SIMD2<Float>(1, 1),
                                               uvMaximum: SIMD2<Float>(-1, -1),
                                               normalOffsetWorld: 0,
                                               texelSizeUV: .zero)
}

/// Per-frame shadow sampling parameters; the layout mirrors `Shadow` in
/// RenderUniforms.h (pinned by `ShadowUniformLayoutTests`).
struct ShadowUniform {
    /// The single shadow window: a pose-invariant disc around the look-at
    /// point, sized by `ShadowSettings.coverageCameraDistances`. Receivers
    /// outside it are lit, and the eye-distance fade hides that edge.
    var cascade: ShadowCascadeUniform
    /// Camera eye in world space, for the distance fade.
    var eye: SIMD3<Float>
    /// Shadow darkening amount in [0, 1]; 0 disables sampling entirely.
    var strength: Float
    var fadeStartDistance: Float
    var fadeEndDistance: Float
    var _padding: Float = 0
    /// Normalized direction towards the static sun: receivers with normals use
    /// it for the geometric self-shadow test (a face turned away from the sun
    /// is in shadow by definition: no map lookup can get that wrong).
    var lightDirection: SIMD3<Float>
    /// RGB cast of a fully shadowed surface, on top of the strength darkening
    /// (`ShadowSettings.tint`); white is the neutral darkening.
    var tint: SIMD3<Float>
    /// Centre of the shadow window in world XY, which the fade distances are
    /// measured from.
    ///
    /// The window is a pose-invariant disc around the point the camera looks
    /// at, and the fade has to be measured the same way or the two describe
    /// different shapes: measuring it from the eye made the fade depend on
    /// pitch, the very thing the disc fit exists to prevent, and closed the
    /// band in front of the visible ground entirely once the radius dropped
    /// below one camera distance, which deleted every shadow in the frame
    /// instead of hiding the window's edge.
    var fadeCenter: SIMD2<Float>
    var _padding1: SIMD2<Float> = .zero

    /// Bound when the shadow pass is skipped: the strength guard in
    /// `sampleShadowFactor` returns 1.0 before touching the texture.
    static let disabled = ShadowUniform(cascade: .disabled,
                                        eye: .zero,
                                        strength: 0,
                                        fadeStartDistance: 0,
                                        fadeEndDistance: 1,
                                        lightDirection: SIMD3<Float>(0, 0, 1),
                                        tint: SIMD3<Float>(repeating: 1),
                                        fadeCenter: .zero)
}
