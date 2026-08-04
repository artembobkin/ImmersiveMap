// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// One shadow cascade's sampling parameters; the layout mirrors `ShadowCascade`
/// in RenderUniforms.h (pinned by `ShadowUniformLayoutTests`).
///
/// `worldToShadowTexture` maps flat world space straight to the cascade's half
/// of the 2:1 shadow atlas: xy is the atlas UV (u compressed to the half and
/// offset, v flipped for Metal's top-left origin), z the comparison depth.
struct ShadowCascadeUniform {
    var worldToShadowTexture: matrix_float4x4
    /// Reserved (kept for layout stability); the tent PCF footprint is a
    /// fixed 3x3 texels.
    var kernelRadiusUV: SIMD2<Float>
    /// Receiver-side comparison bias in normalized shadow depth.
    var depthBias: Float
    /// Cap for the receiver-plane depth gradient (normalized depth per UV);
    /// bounds garbage screen-space derivatives on silhouette quads.
    var gradientClamp: Float
    /// Valid atlas-UV rectangle of this cascade, inset by the kernel reach so
    /// taps never bleed into the neighboring half.
    var uvMinimum: SIMD2<Float>
    var uvMaximum: SIMD2<Float>
    /// World-space distance receivers with normals shift their sample point
    /// along the surface normal (~1.5 texels of this cascade, capped in
    /// meters so the far cascade cannot shift receivers past real occluders):
    /// the receiver leaves its own surface towards the light, so
    /// self-comparison cannot stripe even where the wall's map footprint is
    /// sub-texel, while occluders farther than the cap still shadow it.
    var normalOffsetWorld: Float
    var _padding0: Float = 0
    /// One texel of this cascade in atlas UV (u is a half of the texture):
    /// feeds the per-tap slope-proportional bias that covers the bilinear
    /// compare footprint on steep receivers.
    var texelSizeUV: SIMD2<Float>

    static let disabled = ShadowCascadeUniform(worldToShadowTexture: matrix_identity_float4x4,
                                               kernelRadiusUV: .zero,
                                               depthBias: 0,
                                               gradientClamp: 0,
                                               uvMinimum: SIMD2<Float>(1, 1),
                                               uvMaximum: SIMD2<Float>(-1, -1),
                                               normalOffsetWorld: 0,
                                               texelSizeUV: .zero)
}

/// Per-frame shadow sampling parameters; the layout mirrors `Shadow` in
/// RenderUniforms.h (pinned by `ShadowUniformLayoutTests`).
struct ShadowUniform {
    /// Near cascade: a tight pose-invariant disc around the look-at point for
    /// crisp contact shadows (~sub-meter texels at street zooms).
    var cascadeNear: ShadowCascadeUniform
    /// Middle cascade: where most visible shadows land at a tilted camera, so
    /// meter-scale texels keep diagonal edges straight.
    var cascadeMiddle: ShadowCascadeUniform
    /// Far cascade: the full coverage disc for distant shadows, where a coarse
    /// texel is small on screen and the eye-distance fade takes over.
    var cascadeFar: ShadowCascadeUniform

    var cascades: [ShadowCascadeUniform] {
        [cascadeNear, cascadeMiddle, cascadeFar]
    }
    /// Camera eye in world space, for the distance fade (same convention as
    /// `HorizonFogUniform`).
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

    /// Bound when the shadow pass is skipped: the strength guard in
    /// `sampleShadowFactor` returns 1.0 before touching the texture.
    static let disabled = ShadowUniform(cascadeNear: .disabled,
                                        cascadeMiddle: .disabled,
                                        cascadeFar: .disabled,
                                        eye: .zero,
                                        strength: 0,
                                        fadeStartDistance: 0,
                                        fadeEndDistance: 1,
                                        lightDirection: SIMD3<Float>(0, 0, 1))
}
