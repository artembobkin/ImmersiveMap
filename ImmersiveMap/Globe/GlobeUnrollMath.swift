// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The sphere-to-plane unroll: the CPU mirror of `globeUnrollWorldPosition`
/// in GlobeUnroll.h, term for term, so markers, labels, routes and scene
/// models sit exactly on the morphing surface. Change only in sync with the
/// shader.
///
/// The morph never mixes positions through the planet's interior. Instead
/// the surface lives on a sphere of radius `1 / curvature` tangent to the
/// view centre, with `curvature = (1 - transition) / radius`: every point
/// keeps its distance along the surface from the view centre (blended from
/// the great-circle arc toward the flat Mercator distance) and its azimuth
/// (blended likewise), and the growing sphere flattens the cap into the
/// plane. The surface stays a single-valued convex cap throughout, so
/// nothing ever passes behind or through the planet and no occlusion clip
/// is needed while it unfurls.
enum GlobeUnrollMath {
    static func worldPosition(sphereWorldPosition: SIMD3<Float>,
                              flatWorldPosition: SIMD2<Float>,
                              transition: Float,
                              radius: Float) -> SIMD3<Float> {
        let curvature = (1.0 - transition) / max(radius, 1e-6)
        if curvature <= 1e-9 {
            return SIMD3<Float>(flatWorldPosition.x, flatWorldPosition.y, 0.0)
        }
        let fromCenter = sphereWorldPosition - SIMD3<Float>(0.0, 0.0, -radius)
        let cosTheta = simd_clamp(fromCenter.z / max(radius, 1e-6), -1.0, 1.0)
        let arcSphere = radius * acos(cosTheta)
        let dirSphere = SIMD2<Float>(fromCenter.x, fromCenter.y)
        let dirSphereLength = simd_length(dirSphere)
        let arcFlat = simd_length(flatWorldPosition)
        let azimuthSphere = dirSphereLength > 1e-6 ? dirSphere / dirSphereLength
            : (arcFlat > 1e-6 ? flatWorldPosition / arcFlat : SIMD2<Float>(0.0, 1.0))
        let azimuthFlat = arcFlat > 1e-6 ? flatWorldPosition / arcFlat : azimuthSphere
        let azimuthMix = azimuthSphere + (azimuthFlat - azimuthSphere) * transition
        let azimuthLength = simd_length(azimuthMix)
        let azimuth = azimuthLength > 1e-6 ? azimuthMix / azimuthLength : azimuthSphere
        let arc = arcSphere + (arcFlat - arcSphere) * transition
        let angle = arc * curvature
        let rho = sin(angle) / curvature
        let sag = (cos(angle) - 1.0) / curvature
        return SIMD3<Float>(azimuth.x * rho, azimuth.y * rho, sag)
    }

    /// Soft visibility of a point against the unrolling sphere: the horizon
    /// of the growing sphere the surface lives on. 1 fully visible, 0 hidden
    /// behind the (partly unrolled) planet, feathered over a narrow band. By
    /// the end of the morph the sphere is a plane and hides nothing.
    static func horizonAlpha(worldPosition: SIMD3<Float>,
                             cameraEye: SIMD3<Float>,
                             transition: Float,
                             radius: Float) -> Float {
        let curvature = (1.0 - transition) / max(radius, 1e-6)
        guard curvature > 1e-9 else { return 1.0 }
        let unrollRadius = 1.0 / curvature
        let center = SIMD3<Float>(0.0, 0.0, -unrollRadius)
        let toEye = cameraEye - center
        let normalization = max(simd_length(toEye) * unrollRadius, 1e-6)
        let normalizedDot = simd_dot(worldPosition - center, toEye) / normalization
        let threshold = unrollRadius * unrollRadius / normalization
        let delta = normalizedDot - threshold
        let band: Float = 0.03
        let t = simd_clamp((delta + band) / (2.0 * band), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}
