// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The shading of the ground's slopes this frame (`ImmersiveMapHillshade`):
/// the scene's light, the share of the style's intensity the relief's rise
/// leaves, the style's colours, and how it fades with the distance from
/// the eye, as the fills' fragment stages read them (`GroundReliefUniform`,
/// `groundReliefHillshade` in GroundRelief.h). Resolved once a frame by the
/// store (`GroundReliefStore.setLight`), so every draw on the relief shades
/// by the same light.
struct GroundReliefHillshade: Equatable {
    /// The direction toward the light in the flat basis (+X east, +Y north,
    /// +Z up), unit length, and the amount of shading, the style's
    /// intensity times how far the relief has risen: zero draws none.
    let light: SIMD4<Float>
    let shadowColor: SIMD4<Float>
    let highlightColor: SIMD4<Float>
    /// The eye in the world, where the fade is measured from.
    let eye: SIMD4<Float>
    /// The world distance from the eye the fade starts at, and one over
    /// the world distance it takes to fade out.
    let fade: SIMD4<Float>

    static let none = GroundReliefHillshade(light: SIMD4<Float>(0, 0, 1, 0),
                                            shadowColor: .zero,
                                            highlightColor: .zero,
                                            eye: .zero,
                                            fade: .zero)

    /// The shading of a style under a light (`SceneLightSettings.direction`,
    /// toward the light) with the relief risen by `risenShare`, 0 to 1,
    /// seen from `cameraEye`, the world's origin being the point it looks
    /// at. `fadeCameraDistances` replaces the style's fade (the debug
    /// panel's). A light at or under the horizon shades nothing: the level
    /// ground would be lit as edgewise as the steepest slope.
    static func resolve(style: ImmersiveMapHillshade,
                        lightDirection: SIMD3<Float>,
                        risenShare: Float,
                        cameraEye: SIMD3<Float>,
                        fadeCameraDistances: ClosedRange<Float>? = nil) -> GroundReliefHillshade {
        guard simd_length_squared(lightDirection) > 1e-12 else { return .none }
        let light = simd_normalize(lightDirection)
        let amount = max(0, style.intensity) * min(max(risenShare, 0), 1)
        let cameraDistance = simd_length(cameraEye)
        guard light.z > minimumLightZ, amount > 0, light.x.isFinite, light.y.isFinite, light.z.isFinite,
              cameraDistance.isFinite, cameraDistance > 0 else {
            return .none
        }
        let start = max(0, fadeCameraDistances?.lowerBound ?? style.fadeStartCameraDistances)
        let end = max(start, fadeCameraDistances?.upperBound ?? style.fadeEndCameraDistances)
        let startWorld = start * cameraDistance
        let spanWorld = max((end - start) * cameraDistance, cameraDistance * 1e-3)
        return GroundReliefHillshade(light: SIMD4<Float>(light, amount),
                                     shadowColor: style.shadowColor,
                                     highlightColor: style.highlightColor,
                                     eye: SIMD4<Float>(cameraEye, 0),
                                     fade: SIMD4<Float>(startWorld, 1 / spanWorld, 0, 0))
    }

    /// The lowest light the slopes are shaded by, the sine of its
    /// elevation: about half a degree over the horizon.
    static let minimumLightZ: Float = 0.01
}
