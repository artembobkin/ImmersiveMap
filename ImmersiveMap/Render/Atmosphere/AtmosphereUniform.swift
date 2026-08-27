// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame parameters of the atmosphere halo painted in space around the
/// globe; the layout mirrors `Atmosphere` in Atmosphere.metal (pinned by
/// `AtmosphereUniformLayoutTests`).
///
/// The halo is resolved per pixel from the view ray and the sphere, not from a
/// projected circle: under perspective the silhouette of the globe is a conic,
/// and a screen-space circle would leave the halo detached from the limb on
/// one side of a tilted or off-center view.
struct AtmosphereUniform {
    /// Inverse of the frame's view-projection: turns a far-plane clip point
    /// back into world space, which with the eye gives the view ray.
    var inverseViewProjection: matrix_float4x4
    var eye: SIMD3<Float>
    /// Globe center in world space, `(0, 0, -radius)`: the sphere is
    /// translated so its top touches the flat plane at z = 0.
    var center: SIMD3<Float>
    var color: SIMD3<Float>
    /// Direction toward the sun in world space, or zero when the earth scene
    /// is off and the halo is the same all the way around.
    var sunDirection: SIMD3<Float>
    var radius: Float
    /// Geometry transition of the globe: the halo fades out over the first
    /// part of the unfurl, before the sphere silhouette it is fitted to moves.
    var transition: Float
    var intensity: Float
    var thickness: Float
    var sunInfluence: Float
    var _padding0: Float = 0
    var _padding1: Float = 0
    var _padding2: Float = 0

    static func make(settings: ImmersiveMapSettings.AtmosphereSettings,
                     earthScene: EarthSceneUniform,
                     globe: GlobeUniform,
                     projectionView: matrix_float4x4,
                     cameraEye: SIMD3<Float>) -> AtmosphereUniform {
        let sunDirection: SIMD3<Float>
        if earthScene.isEnabled != 0,
           settings.sunInfluence > 0,
           simd_length_squared(earthScene.sunDirection) > 1e-8 {
            // The scene's sun is earth-fixed (the frame the unrotated sphere
            // normals live in); the halo works on world-space rays, so the
            // sun goes through the same rotation the sphere does.
            let rotation = EarthSceneSunVisualState.globeRotationMatrix(globe: globe)
            let rotated = simd_transpose(rotation) * SIMD4<Float>(simd_normalize(earthScene.sunDirection), 0)
            sunDirection = simd_normalize(SIMD3<Float>(rotated.x, rotated.y, rotated.z))
        } else {
            sunDirection = .zero
        }
        // The terminator fades off the surface between zoom 1 and 2
        // (`sunShadowFade`), and the halo's day/night asymmetry goes with it:
        // a halo still dimmed on one side of a planet that shows no night
        // would read as a lopsided ring.
        let sunInfluence = min(Self.clampedNonNegative(settings.sunInfluence), 1)
            * (1 - Self.clampedUnit(earthScene.sunShadowFade))
        return AtmosphereUniform(inverseViewProjection: simd_inverse(projectionView),
                                 eye: cameraEye,
                                 center: SIMD3<Float>(0, 0, -globe.radius),
                                 color: Self.clampedUnit(settings.color),
                                 sunDirection: sunDirection,
                                 radius: globe.radius,
                                 transition: globe.transition,
                                 intensity: Self.clampedNonNegative(settings.intensity),
                                 thickness: Self.clampedNonNegative(settings.thickness),
                                 sunInfluence: sunInfluence)
    }

    private static func clampedUnit(_ color: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(clampedUnit(color.x), clampedUnit(color.y), clampedUnit(color.z))
    }

    private static func clampedUnit(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func clampedNonNegative(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }
}

/// The atmosphere's glow on the globe surface toward the limb; the layout
/// mirrors `GlobeAtmosphere` in RenderUniforms.h. Bound to the globe surface,
/// its placeholder fill and the polar caps, so the three shade identically.
struct GlobeAtmosphereUniform {
    var color: SIMD3<Float>
    /// Zero when the atmosphere is off: the surface then carries no glow and
    /// the limb is a hard edge.
    var intensity: Float
    /// Direction toward the sun in world space (the frame the surface's view
    /// direction lives in), or zero without an earth scene: the rim light at
    /// the limb is forward scattering and needs to know whether the sun is
    /// on the far side of the air from the eye.
    var sunDirection: SIMD3<Float>
    var _padding0: Float = 0

    static let disabled = GlobeAtmosphereUniform(color: .zero, intensity: 0, sunDirection: .zero)

    static func make(settings: ImmersiveMapSettings.AtmosphereSettings,
                     earthScene: EarthSceneUniform = .disabled,
                     globe: GlobeUniform = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0)) -> GlobeAtmosphereUniform {
        guard settings.isEnabled, settings.intensity > 0, settings.intensity.isFinite else {
            return .disabled
        }
        return GlobeAtmosphereUniform(color: SIMD3<Float>(min(max(settings.color.x, 0), 1),
                                                          min(max(settings.color.y, 0), 1),
                                                          min(max(settings.color.z, 0), 1)),
                                      intensity: settings.intensity,
                                      sunDirection: worldSunDirection(earthScene: earthScene, globe: globe))
    }

    /// The earth-fixed sun carried into world space through the globe's
    /// rotation, as the halo does; zero without an earth scene.
    static func worldSunDirection(earthScene: EarthSceneUniform, globe: GlobeUniform) -> SIMD3<Float> {
        guard earthScene.isEnabled != 0,
              simd_length_squared(earthScene.sunDirection) > 1e-8 else {
            return .zero
        }
        let rotation = EarthSceneSunVisualState.globeRotationMatrix(globe: globe)
        let rotated = simd_transpose(rotation) * SIMD4<Float>(simd_normalize(earthScene.sunDirection), 0)
        return simd_normalize(SIMD3<Float>(rotated.x, rotated.y, rotated.z))
    }
}
