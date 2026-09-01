// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The sphere-to-plane unroll: the CPU mirror of `globeUnrollWorldPosition`
/// in GlobeUnroll.h, term for term, so markers, labels, routes and scene
/// models sit exactly on the morphing surface. Change only in sync with the
/// shader.
///
/// The morph never mixes positions through the planet's interior. The
/// surface lives on a sphere of radius `1 / curvature` tangent to the view
/// centre, with `curvature = (1 - transition) / radius`, and every point
/// travels a straight line in the chart: between its azimuthal-equidistant
/// image about the view centre (arc times bearing; wrapping that chart back
/// onto the sphere of radius R is the identity) and its Mercator position,
/// with the blended chart point wrapped onto the growing sphere. No
/// direction snapping, so triangles do not fold into slivers; the blend's
/// fold-freedom is swept numerically by GlobeUnrollFoldTests.
enum GlobeUnrollMath {
    /// The unroll's cut as a fraction of the planet radius, mirrored from
    /// GlobeUnroll.h: a point is hidden while its remaining chart travel
    /// exceeds this, and appears only when it is nearly home. At transition
    /// 0 the hidden set is exactly the content whose two charts disagree,
    /// never visible on the resting sphere; by 1 everything has arrived.
    static let cutTravelFraction: Float = 0.25

    /// The azimuthal-equidistant image of a sphere position about the view
    /// centre, mirroring `globeUnrollChartAE`.
    static func chartAE(sphereWorldPosition: SIMD3<Float>, radius: Float) -> SIMD2<Float> {
        let fromCenter = sphereWorldPosition - SIMD3<Float>(0.0, 0.0, -radius)
        let cosTheta = simd_clamp(fromCenter.z / max(radius, 1e-6), -1.0, 1.0)
        let arcSphere = radius * acos(cosTheta)
        let dirSphere = SIMD2<Float>(fromCenter.x, fromCenter.y)
        let dirSphereLength = simd_length(dirSphere)
        return dirSphereLength > 1e-6 ? dirSphere * (arcSphere / dirSphereLength) : SIMD2<Float>(0.0, 0.0)
    }

    /// Mirror of `globeUnrollCutClearance`: positive once the point's
    /// remaining chart travel is short enough to show.
    static func cutClearance(sphereWorldPosition: SIMD3<Float>,
                             flatWorldPosition: SIMD2<Float>,
                             transition: Float,
                             radius: Float) -> Float {
        let chart = chartAE(sphereWorldPosition: sphereWorldPosition, radius: radius)
        let remaining = (1.0 - transition) * simd_length(flatWorldPosition - chart)
        return cutTravelFraction - remaining / max(radius, 1e-6)
    }

    static func worldPosition(sphereWorldPosition: SIMD3<Float>,
                              flatWorldPosition: SIMD2<Float>,
                              transition: Float,
                              radius: Float) -> SIMD3<Float> {
        let curvature = (1.0 - transition) / max(radius, 1e-6)
        if curvature <= 1e-9 {
            return SIMD3<Float>(flatWorldPosition.x, flatWorldPosition.y, 0.0)
        }
        let azimuthalEquidistant = chartAE(sphereWorldPosition: sphereWorldPosition, radius: radius)
        let chartPoint = azimuthalEquidistant + (flatWorldPosition - azimuthalEquidistant) * transition
        let arc = simd_length(chartPoint)
        if arc <= 1e-6 {
            return SIMD3<Float>(chartPoint.x, chartPoint.y, 0.0)
        }
        let azimuth = chartPoint / arc
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
