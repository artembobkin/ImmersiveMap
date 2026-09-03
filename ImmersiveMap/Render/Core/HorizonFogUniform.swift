// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Haze at the horizon; the layout mirrors `HorizonFog` in RenderUniforms.h
/// (pinned by `HorizonFogUniformTests`).
///
/// Two parts. The seam fog measures distance in eye heights above the plane:
/// it starts at `startEyeHeights` (angular ≈ atan(1/12) ≈ 4.8° below the
/// vanishing line) and saturates to the frame's clear colour by
/// `endEyeHeights` (≈ 0.5°), a band geometrically glued to the vanishing line
/// at any zoom and tilt, which is what hides the coverage edge and the
/// horizon-line seam of the surface switch. The haze is the globe
/// atmosphere's profile measured by angle from the visible edge of the
/// surface: the limb of the sphere the surface currently lives on (the
/// unroll keeps it a sphere of radius R / (1 - t), `GlobeUnroll.h`), which at
/// t = 1 is the plane's horizon. Its widths morph from the resting halo's
/// (fixed fractions of the radius, converted to angle at the limb for the
/// frame's eye) to the plane's narrow band, so the air follows the edge
/// through the morph without changing character. Off under transparent
/// space, where no sky is painted and the ground must still meet the clear
/// colour.
///
/// `strength` equals the globe→flat transition phase: no seam fog on the pure
/// globe, it fades in during the morph, and by the surface switch both sides
/// are fogged identically, hiding the horizon-line seam. The haze comes in
/// over the first tenth of the morph, taking over from the resting halo's
/// inward rim.
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
    var limbRadius: Float

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

    /// The resting halo's widths, in globe radii of miss distance past the
    /// limb; mirrors `kAtmosphereBandWidth` and its siblings in
    /// Atmosphere.metal (pinned by `HorizonFogUniformTests`).
    static let haloBandRadii: Float = 0.075
    static let haloGlowRadii: Float = 0.34
    static let haloWhitenRadii: Float = 0.018

    /// The plane's haze profile, radians of angle from the horizon: a
    /// horizon effect, not a tint over the map. The dense band hugging the
    /// line, the faint glow away from it, the whitening right at it.
    static let planeBandRadians: Float = 2 * .pi / 180
    static let planeGlowRadians: Float = 10 * .pi / 180
    static let planeWhitenRadians: Float = 0.7 * .pi / 180
    /// The ground haze fades out between 1.2 and 2.5 glow widths under the
    /// edge and is exactly zero past that (`kHorizonHazeCutoff*Glows`).
    static let hazeCutoffStartGlows: Float = 1.2
    static let hazeCutoffEndGlows: Float = 2.5
    /// The haze takes over from the resting halo's inward rim over the first
    /// tenth of the morph.
    static let hazeRampEnd: Float = 0.1

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
                                            limbRadius: 0)

    /// - Parameters:
    ///   - transition: the semantic transition (strengths).
    ///   - geometryTransition: the unroll's transition (the current sphere).
    ///   - globeRadius: the resting sphere's radius in render units.
    ///   - hazeEnabled: false under transparent space: the frame paints no
    ///     sky there, so the ground must meet the clear colour.
    static func make(transition: Float,
                     geometryTransition: Float? = nil,
                     cameraEye: SIMD3<Float>,
                     mapClearColor: SIMD4<Double>,
                     globeRadius: Float = 1,
                     hazeEnabled: Bool = true) -> HorizonFogUniform {
        let t = min(max(transition, 0), 1)
        let geometry = min(max(geometryTransition ?? t, 0), 1)
        let widths = hazeWidths(transition: geometry, cameraEye: cameraEye, globeRadius: globeRadius)
        let ramp = min(max(t / hazeRampEnd, 0), 1)
        return HorizonFogUniform(color: SIMD3<Float>(Float(mapClearColor.x),
                                                     Float(mapClearColor.y),
                                                     Float(mapClearColor.z)),
                                 eye: cameraEye,
                                 strength: t,
                                 startEyeHeights: defaultStartEyeHeights,
                                 endEyeHeights: defaultEndEyeHeights,
                                 hazeStrength: hazeEnabled ? ramp * ramp * (3 - 2 * ramp) : 0,
                                 hazeColor: AtmosphereUniform.haloColor,
                                 bandRadians: widths.band,
                                 glowRadians: widths.glow,
                                 whitenRadians: widths.whiten,
                                 limbRadius: limbRadius(geometryTransition: geometry, globeRadius: globeRadius))
    }

    /// The sphere the surface lives on at this point of the unroll, zero on
    /// the plane (the last hundredth is treated as the plane: the sphere is
    /// then too flat for the limb angle to be computed in float).
    static func limbRadius(geometryTransition: Float, globeRadius: Float) -> Float {
        let curvature = 1 - geometryTransition
        guard curvature > 0.01 else { return 0 }
        return globeRadius / curvature
    }

    /// The haze widths for the frame: the resting halo's radii widths
    /// converted to angle at the limb (miss distance over the eye's distance
    /// to the limb point), morphed to the plane's widths with the unroll.
    static func hazeWidths(transition: Float,
                           cameraEye: SIMD3<Float>,
                           globeRadius: Float) -> (band: Float, glow: Float, whiten: Float) {
        let toCenter = SIMD3<Float>(0, 0, -globeRadius) - cameraEye
        let distance = simd_length(toCenter)
        let limbDistance = (max(distance * distance - globeRadius * globeRadius, 1e-6)).squareRoot()
        // Perpendicular miss distance over the distance to the limb point is
        // the angle to first order; capped so a camera almost touching the
        // sphere does not blow the halo up to the whole sky.
        func angle(_ radii: Float) -> Float {
            min(radii * globeRadius / limbDistance, 45 * .pi / 180)
        }
        let s = transition * transition * (3 - 2 * transition)
        return (band: angle(haloBandRadii) + (planeBandRadians - angle(haloBandRadii)) * s,
                glow: angle(haloGlowRadii) + (planeGlowRadians - angle(haloGlowRadii)) * s,
                whiten: angle(haloWhitenRadii) + (planeWhitenRadians - angle(haloWhitenRadii)) * s)
    }

    /// CPU mirror of `horizonHazeAmount` on the plane: how much haze covers
    /// the ground at an angle below the horizon, before the strengths.
    static func planeHazeAmount(belowRadians: Float) -> Float {
        let band = exp(-belowRadians / planeBandRadians)
        let glow = exp(-belowRadians / planeGlowRadians)
        let profile = min(max(band * 0.85 + glow * 0.22, 0), 1)
        let start = hazeCutoffStartGlows * planeGlowRadians
        let end = hazeCutoffEndGlows * planeGlowRadians
        let t = min(max((belowRadians - start) / (end - start), 0), 1)
        return profile * (1 - t * t * (3 - 2 * t))
    }
}
