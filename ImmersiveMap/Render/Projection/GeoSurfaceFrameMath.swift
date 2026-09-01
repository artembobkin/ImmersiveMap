// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A geocoordinate resolved onto the (possibly mid-morph) map surface: the
/// world position, the local tangent frame, and how many render units one
/// ground meter spans there.
struct GeoSurfaceFrame {
    /// Position on the surface itself; altitude is applied by the caller as
    /// `worldPosition + up * altitudeMeters * unitsPerMeter`.
    let worldPosition: SIMD3<Float>
    /// Spherical position before the unfurl blend, kept for the horizon test.
    let sphereWorldPosition: SIMD3<Float>
    let east: SIMD3<Float>
    let north: SIMD3<Float>
    let up: SIMD3<Float>
    let unitsPerMeter: Float
    /// Phase of the sphere-to-plane unroll, 0...1 (uniform across the
    /// surface: the unroll has no per-point wave).
    let localTransition: Float
    /// X of the flat morph target after unwrapping. Feed it back as the next
    /// `flatWorldXReference` when resolving a chain of points, otherwise
    /// neighbours straddling the antimeridian jump by a whole map width.
    let flatWorldX: Float
    /// False when the point is beyond the globe horizon gate. The depth test
    /// would hide surface geometry anyway; this only lets callers skip a draw.
    let passesHorizonGate: Bool
}

/// CPU evaluation of the sphere-plane morph for a single geocoordinate:
/// position, blended tangent frame, and meter scale come from the same formulas
/// as `GeoScreenProjectionMath` (the CPU mirror of the globe shaders), so
/// anything anchored through this function sits exactly on the morph geometry.
///
/// Shared by scene model anchors and route tessellation: the model rides
/// exactly on the drawn line because both resolve their position here.
enum GeoSurfaceFrameMath {
    /// Mercator clamps at +-85.05 degrees, so the flat meter scale never
    /// divides by a vanishing cos(latitude).
    private static let minimumCosLatitude = Float(cos(ImmersiveMapProjection.maxMercatorLatitude))

    static func resolve(basis: GeoProjectionBasis,
                        constants: GeoScreenProjectionMath.FrameConstants,
                        flatWorldXReference: Float? = nil) -> GeoSurfaceFrame {
        let cosLatitude = max(simd_length(SIMD2<Float>(basis.sphereUnit.x, basis.sphereUnit.z)),
                              minimumCosLatitude)
        let earthCircumference = Float(ImmersiveMapProjection.earthCircumferenceMeters)

        switch constants.mode {
        case .flat:
            // Mirror of GeoScreenProjectionMath.projectFlat.
            let halfMapSize = constants.flatRenderMapSize * 0.5
            let wrappedX = ImmersiveMapProjection.wrap(
                value: basis.normalizedWorldX * constants.flatRenderMapSize - halfMapSize
                    + constants.flatPan.x * halfMapSize,
                size: constants.flatRenderMapSize)
            let xWorld = unwrapped(Float(wrappedX),
                                   reference: flatWorldXReference,
                                   size: Float(constants.flatRenderMapSize))
            let yWorld = (basis.mercatorYNormalized - constants.flatPan.y) * halfMapSize
            let worldPosition = SIMD3<Float>(xWorld, Float(yWorld), 0)
            return GeoSurfaceFrame(worldPosition: worldPosition,
                                   sphereWorldPosition: worldPosition,
                                   east: SIMD3<Float>(1, 0, 0),
                                   north: SIMD3<Float>(0, 1, 0),
                                   up: SIMD3<Float>(0, 0, 1),
                                   unitsPerMeter: Float(constants.flatRenderMapSize)
                                       / (earthCircumference * cosLatitude),
                                   localTransition: 1,
                                   flatWorldX: xWorld,
                                   passesHorizonGate: true)
        case .globe:
            // Mirror of GeoScreenProjectionMath.projectGlobe.
            let sphereWorldPosition = constants.rotatedSphereWorldPosition(sphereUnit: basis.sphereUnit)
            var flatWorldPosition = constants.globeFlatWorldPosition(basis: basis)
            flatWorldPosition.x = unwrapped(flatWorldPosition.x,
                                            reference: flatWorldXReference,
                                            size: constants.globeMapSize)
            let transition = constants.globe.transition
            let worldPosition: SIMD3<Float>
            if transition <= 0.0 {
                worldPosition = sphereWorldPosition
            } else {
                worldPosition = GlobeUnrollMath.worldPosition(sphereWorldPosition: sphereWorldPosition,
                                                              flatWorldPosition: SIMD2<Float>(flatWorldPosition.x,
                                                                                              flatWorldPosition.y),
                                                              transition: transition,
                                                              radius: constants.globe.radius)
            }

            // Tangent frame on the unit sphere (pre-rotation): up is the sphere
            // normal, east is d/dLongitude; degenerate exactly at the poles.
            let sphereUp = basis.sphereUnit
            let eastRaw = SIMD3<Float>(sphereUp.z, 0, -sphereUp.x)
            let eastLength = simd_length(eastRaw)
            let sphereEast = eastLength > 1e-5 ? eastRaw / eastLength : SIMD3<Float>(1, 0, 0)
            let rotatedUp = rotateDirection(sphereUp, constants: constants)
            let rotatedEast = rotateDirection(sphereEast, constants: constants)

            // Blend toward the flat basis by the unroll phase and
            // re-orthonormalize: geometry tilts upright together with the
            // surface it stands on.
            let up = simd_normalize(blend(rotatedUp, SIMD3<Float>(0, 0, 1), transition))
            let eastReference = simd_normalize(blend(rotatedEast, SIMD3<Float>(1, 0, 0), transition))
            let north = simd_normalize(simd_cross(up, eastReference))
            let east = simd_cross(north, up)

            // Meter scale: true ground meters on the sphere (2piR per Earth
            // circumference), inflating toward the Mercator 1/cos(latitude)
            // convention as the point unfurls into the plane.
            let sphereScale = 2 * Float.pi * constants.globe.radius / earthCircumference
            let flatScale = constants.globeMapSize / (earthCircumference * cosLatitude)
            let unitsPerMeter = sphereScale + (flatScale - sphereScale) * transition

            let visibility = GeoScreenProjectionMath.globeVisibility(worldPosition: worldPosition,
                                                                     sphereWorldPosition: sphereWorldPosition,
                                                                     flatWorldPosition: SIMD2<Float>(flatWorldPosition.x,
                                                                                                     flatWorldPosition.y),
                                                                     constants: constants)

            return GeoSurfaceFrame(worldPosition: worldPosition,
                                   sphereWorldPosition: sphereWorldPosition,
                                   east: east,
                                   north: north,
                                   up: up,
                                   unitsPerMeter: unitsPerMeter,
                                   localTransition: transition,
                                   flatWorldX: flatWorldPosition.x,
                                   passesHorizonGate: visibility.visible && visibility.alpha > 0)
        }
    }

    /// Brings `value` into the copy of the wrapped world nearest `reference`.
    /// Both wraps (flat and globe-morph) fold X into one map width, which turns
    /// a seam crossing into a full-width jump between neighbouring points.
    private static func unwrapped(_ value: Float, reference: Float?, size: Float) -> Float {
        guard let reference, size > 0 else { return value }
        let halfSize = size * 0.5
        var result = value
        while result - reference > halfSize {
            result -= size
        }
        while reference - result > halfSize {
            result += size
        }
        return result
    }

    /// Applies the globe pan rotation to a direction, matching
    /// `FrameConstants.rotatedSphereWorldPosition` (w = 0: no translation).
    private static func rotateDirection(_ direction: SIMD3<Float>,
                                        constants: GeoScreenProjectionMath.FrameConstants) -> SIMD3<Float> {
        let rotated = constants.globeTransposedRotationMatrix * SIMD4<Float>(direction, 0)
        return rotated.xyz
    }

    private static func blend(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        from + (to - from) * t
    }
}
