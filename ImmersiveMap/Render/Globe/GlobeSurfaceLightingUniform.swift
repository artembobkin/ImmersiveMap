// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame parameters of the deferred globe-surface lighting pass; the
/// layout mirrors `GlobeSurfaceLighting` in GlobeSurfaceLighting.metal
/// (pinned by `GlobeSurfaceLightingUniformLayoutTests`).
///
/// The pass resolves each pixel's place on the sphere analytically from the
/// view ray, the way the atmosphere halo does, so the uniform carries the
/// ray reconstruction (the inverse view-projection and the eye) and the
/// sphere (center, radius), plus the sun already rotated into world space:
/// dot products against world-space normals equal the earth-frame ones the
/// inline path takes, the rotation being orthonormal.
struct GlobeSurfaceLightingUniform {
    var inverseViewProjection: matrix_float4x4
    var eye: SIMD3<Float>
    /// Globe center in world space, `(0, 0, -radius)`.
    var center: SIMD3<Float>
    /// Direction toward the sun in world space, or zero when the earth scene
    /// is off.
    var worldSunDirection: SIMD3<Float>
    var radius: Float
    var _padding0: Float = 0
    var _padding1: Float = 0
    var _padding2: Float = 0

    static func make(globe: GlobeUniform,
                     earthScene: EarthSceneUniform,
                     projectionView: matrix_float4x4,
                     cameraEye: SIMD3<Float>) -> GlobeSurfaceLightingUniform {
        GlobeSurfaceLightingUniform(inverseViewProjection: simd_inverse(projectionView),
                                    eye: cameraEye,
                                    center: SIMD3<Float>(0, 0, -globe.radius),
                                    worldSunDirection: GlobeAtmosphereUniform.worldSunDirection(earthScene: earthScene,
                                                                                                globe: globe),
                                    radius: globe.radius)
    }
}
