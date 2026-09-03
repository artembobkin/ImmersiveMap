// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame parameters of the atmosphere painted around the globe's limb;
/// the layout mirrors `Atmosphere` in Atmosphere.metal (pinned by
/// `AtmosphereUniformLayoutTests`).
///
/// The look is fixed by the constants below rather than settings: the
/// atmosphere is part of the globe's stock appearance, one halo tint and one
/// designed profile, and turning the space décor off (`SpaceSettings
/// .isTransparent`) is what turns it off.
struct AtmosphereUniform {
    /// Inverse of the frame's view-projection: turns a far-plane clip point
    /// back into world space, which with the eye gives the view ray.
    var inverseViewProjection: matrix_float4x4
    var eye: SIMD3<Float>
    /// Globe center in world space, `(0, 0, -radius)`: the sphere is
    /// translated so its top touches the flat plane at z = 0.
    var center: SIMD3<Float>
    var color: SIMD3<Float>
    var radius: Float
    /// Geometry transition of the globe: the halo fades out over the first
    /// part of the unfurl, before the limb it is fitted to moves.
    var transition: Float
    var intensity: Float
    var thickness: Float
    /// The horizon haze the ground draws with: past the resting sphere the
    /// halo is its sky side, measured by angle from the current edge.
    var fog: HorizonFogUniform

    /// Sky blue; the very edge whitens toward the limb in the shader.
    static let haloColor = SIMD3<Float>(0.40, 0.66, 1.0)
    static let haloIntensity: Float = 1.0
    static let haloThickness: Float = 1.0

    static func make(globe: GlobeUniform,
                     projectionView: matrix_float4x4,
                     cameraEye: SIMD3<Float>,
                     fog: HorizonFogUniform) -> AtmosphereUniform {
        AtmosphereUniform(inverseViewProjection: simd_inverse(projectionView),
                          eye: cameraEye,
                          center: SIMD3<Float>(0, 0, -globe.radius),
                          color: haloColor,
                          radius: globe.radius,
                          transition: globe.transition,
                          intensity: haloIntensity,
                          thickness: haloThickness,
                          fog: fog)
    }
}
