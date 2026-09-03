// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Haze at the horizon of the flat presentation; the layout mirrors `HorizonFog`
/// in RenderUniforms.h (pinned by `HorizonFogUniformTests`).
///
/// Two parts. The seam fog measures distance in eye heights above the plane:
/// it starts at `startEyeHeights` (angular ≈ atan(1/12) ≈ 4.8° below the
/// vanishing line) and saturates to the frame's clear colour by
/// `endEyeHeights` (≈ 0.5°), a band geometrically glued to the vanishing line
/// at any zoom and tilt, which is what hides the coverage edge and the
/// horizon-line seam of the surface switch. The haze is the globe
/// atmosphere's profile turned inward: three exponentials of the pixel's
/// angle below the horizon in the halo's tint, so the far range dissolves
/// into the same air the limb wore on the sphere, and the sky above the
/// line continues the profile upward (`FlatSkyUniform`). Off under
/// transparent space, where no sky is painted and the ground must still
/// meet the clear colour.
///
/// `strength` equals the globe→flat transition phase: no fog on the pure globe,
/// it fades in smoothly during the morph, and by the surface switch both sides
/// are fogged identically, hiding the horizon-line seam.
struct HorizonFogUniform {
    var color: SIMD3<Float>
    var eye: SIMD3<Float>
    var strength: Float
    var startEyeHeights: Float
    var endEyeHeights: Float
    var hazeStrength: Float
    var hazeColor: SIMD3<Float>
    var bandRadians: Float
    var glowRadians: Float
    var whitenRadians: Float
    var skyBandRadians: Float

    static let defaultStartEyeHeights: Float = 12
    /// Full opacity must be reached BEFORE the nearest possible edge of the
    /// tile coverage, otherwise the backdrop flashes beyond it during the
    /// surface switch. Edge = coverage radius (40 tiles of the target zoom ×
    /// 2π·globeRadiusScale ≈ 35.2 render units) at the maximum eye height
    /// 0.25 → minimum ≈ 140 heights. 120 leaves margin; angular that is
    /// ≈ atan(1/120) ≈ 0.48° below the vanishing line, a thin rim right at the
    /// horizon. Recompute if `VisibleTilesPreprocessor.defaultMaxVisibleRelativeDistance`
    /// or `globeRadiusScale` changes.
    static let defaultEndEyeHeights: Float = 120

    /// The haze profile, in radians of angle from the horizon line. The
    /// dense band hugging the line, the wide faint glow down the plain, the
    /// whitening right at the line, and the sky's deepening above it. The
    /// same three-part shape as the globe halo (`Atmosphere.metal`), whose
    /// widths are in globe radii past the limb; here the angle is the
    /// natural measure, since it is what a tilt changes.
    static let hazeBandRadians: Float = 6 * .pi / 180
    static let hazeGlowRadians: Float = 20 * .pi / 180
    static let hazeWhitenRadians: Float = 2 * .pi / 180
    static let skyBandRadians: Float = 8 * .pi / 180
    /// The haze fades out between 20 and 40 degrees under the line and is
    /// exactly zero past that (`kHorizonHazeCutoff*` in RenderUniforms.h).
    static let hazeCutoffStartRadians: Float = 20 * .pi / 180
    static let hazeCutoffEndRadians: Float = 40 * .pi / 180

    static let disabled = HorizonFogUniform(color: .zero,
                                            eye: .zero,
                                            strength: 0,
                                            startEyeHeights: 1,
                                            endEyeHeights: 2,
                                            hazeStrength: 0,
                                            hazeColor: .zero,
                                            bandRadians: 1,
                                            glowRadians: 1,
                                            whitenRadians: 1,
                                            skyBandRadians: 1)

    /// - Parameter hazeEnabled: false under transparent space: the frame
    ///   paints no sky there, so the ground must meet the clear colour.
    static func make(transition: Float,
                     cameraEye: SIMD3<Float>,
                     mapClearColor: SIMD4<Double>,
                     hazeEnabled: Bool = true) -> HorizonFogUniform {
        HorizonFogUniform(color: SIMD3<Float>(Float(mapClearColor.x),
                                              Float(mapClearColor.y),
                                              Float(mapClearColor.z)),
                          eye: cameraEye,
                          strength: min(max(transition, 0), 1),
                          startEyeHeights: defaultStartEyeHeights,
                          endEyeHeights: defaultEndEyeHeights,
                          hazeStrength: hazeEnabled ? 1 : 0,
                          hazeColor: AtmosphereUniform.haloColor,
                          bandRadians: hazeBandRadians,
                          glowRadians: hazeGlowRadians,
                          whitenRadians: hazeWhitenRadians,
                          skyBandRadians: skyBandRadians)
    }

    /// CPU mirror of `horizonHazeAmount`: how much haze covers the ground at
    /// an angle below the horizon, before the transition strength.
    static func hazeAmount(belowRadians: Float) -> Float {
        let band = exp(-belowRadians / hazeBandRadians)
        let glow = exp(-belowRadians / hazeGlowRadians)
        let profile = min(max(band * 0.85 + glow * 0.22, 0), 1)
        // The cutoff: gone by 40 degrees under the line, so a downward view
        // stays byte-clean.
        let t = min(max((belowRadians - 20 * .pi / 180) / (20 * .pi / 180), 0), 1)
        return profile * (1 - t * t * (3 - 2 * t))
    }
}
