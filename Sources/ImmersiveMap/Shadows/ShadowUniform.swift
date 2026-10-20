// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// One shadow window's sampling parameters; the layout mirrors
/// `ShadowCascade` in RenderUniforms.h (pinned by `ShadowUniformLayoutTests`).
///
/// `worldToShadowTexture` maps flat world space straight to the window's
/// slice of the shadow map: xy is the texture UV (v flipped for Metal's
/// top-left origin), z the comparison depth.
struct ShadowCascadeUniform {
    var worldToShadowTexture: matrix_float4x4
    /// Softness of the shadow's edge: the factor the tent's four taps are
    /// pushed out by, about the sample point (`ShadowSettings.softness`,
    /// clamped to `ShadowFrameStateResolver.softnessRange`). 1 is the plain
    /// 3x3 tent. The kernel stays symmetric about the sample point, so a
    /// wider spread lengthens the ramp without moving the shadow's edge.
    var tentSpread: Float
    /// Where this window's shadows start to fade and where they are gone,
    /// as radial distances from `ShadowUniform.fadeCenter`: the outer
    /// quarter of the window's disc (`ShadowFrameStateResolver.fadeDistances`).
    /// For the near window the band is where the far window takes over,
    /// for the far window, or the near one alone, where the shadows end.
    var fadeStartDistance: Float
    /// Receiver-side comparison bias in normalized shadow depth.
    var depthBias: Float
    var fadeEndDistance: Float
    /// Valid UV rectangle, inset so the tent's taps never leave the fitted
    /// window, at the widest spread `softnessRange` allows. An empty
    /// rectangle (minimum past maximum) is a window the frame has not got.
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
                                               fadeStartDistance: 0,
                                               depthBias: 0,
                                               fadeEndDistance: 1,
                                               uvMinimum: SIMD2<Float>(1, 1),
                                               uvMaximum: SIMD2<Float>(-1, -1),
                                               normalOffsetWorld: 0,
                                               texelSizeUV: .zero)

    /// Whether the frame has this window (the shader's `shadowCascadeIsEnabled`).
    var isEnabled: Bool { uvMaximum.x >= uvMinimum.x }
}

/// Per-frame shadow sampling parameters; the layout mirrors `Shadow` in
/// RenderUniforms.h (pinned by `ShadowUniformLayoutTests`).
struct ShadowUniform {
    /// The near window (`ShadowCascadeSlot.near`): a disc around the point
    /// the camera looks at, sized by `ShadowSettings.nearCoverageMeters`.
    var near: ShadowCascadeUniform
    /// The far window (`ShadowCascadeSlot.far`), sized by
    /// `farCoverageMeters`, `.disabled` when the frame has none.
    /// A receiver outside both is lit, and the far window's fade (the near
    /// one's without it) hides that edge.
    var far: ShadowCascadeUniform
    /// Camera eye in world space.
    var eye: SIMD3<Float>
    /// Shadow darkening amount in [0, 1]; 0 disables sampling entirely.
    var strength: Float
    var _padding0: Float = 0
    var _padding1: Float = 0
    var _padding2: Float = 0
    /// Normalized direction towards the static sun: receivers with normals use
    /// it for the geometric self-shadow test (a face turned away from the sun
    /// is in shadow by definition: no map lookup can get that wrong).
    var lightDirection: SIMD3<Float>
    /// RGB cast of a fully shadowed surface, on top of the strength darkening
    /// (`ShadowSettings.tint`); white is the neutral darkening.
    var tint: SIMD3<Float>
    /// Centre of the windows in world XY, which every fade distance is
    /// measured from: the camera's ground point, the centre of the circle
    /// the visible footprint is clamped to, the only window edge a viewer
    /// can reach. Measured from the look-at point the fade depended on the
    /// pitch, and closed in front of the visible ground entirely once the
    /// radius dropped below one camera distance.
    var fadeCenter: SIMD2<Float>
    var _padding3: SIMD2<Float> = .zero

    /// Bound when the shadow pass is skipped: the strength guard in
    /// `sampleShadowFactor` returns 1.0 before touching the texture.
    static let disabled = ShadowUniform(near: .disabled,
                                        far: .disabled,
                                        eye: .zero,
                                        strength: 0,
                                        lightDirection: SIMD3<Float>(0, 0, 1),
                                        tint: SIMD3<Float>(repeating: 1),
                                        fadeCenter: .zero)
}
