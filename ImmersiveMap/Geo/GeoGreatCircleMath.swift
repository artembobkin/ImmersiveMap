// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Great-circle math: interpolation between coordinates, central angle and
/// forward azimuth. It lives in `Geo` because both the scene model animation
/// (`SceneModels`) and route tessellation (`Routes`) need it, and domain
/// folders must not depend on each other.
///
/// Everything is computed in `Double`. The path sampler measures segments a few
/// kilometers long, where a `Float` dot product near 1 has no significant bits
/// left and the central angle degenerates to noise.
enum GeoGreatCircleMath {
    /// Below this angle the two coordinates are the same point for every
    /// practical purpose (about 6 mm on Earth) and the great circle through
    /// them is undefined.
    private static let degenerateAngleRadians = 1e-9
    /// Below this sine the endpoints are antipodal: the weights blow up and the
    /// blended vector loses every significant bit to cancellation.
    private static let antipodalSineThreshold = 1e-7

    /// Great-circle interpolation over unit vectors: correct near the
    /// antimeridian and the poles, unlike a lat/lon lerp.
    static func coordinate(from start: GeoCoordinate,
                           to target: GeoCoordinate,
                           progress: Double) -> GeoCoordinate {
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else { return start }
        guard clampedProgress < 1 else { return target }

        let fromVector = unitVector(for: start)
        let toVector = unitVector(for: target)
        let angle = centralAngle(fromVector: fromVector, toVector: toVector)
        guard angle > degenerateAngleRadians else { return start }

        let sinAngle = sin(angle)
        guard sinAngle > antipodalSineThreshold else {
            return antipodalCoordinate(from: start, to: target, progress: clampedProgress)
        }

        let startWeight = sin((1 - clampedProgress) * angle) / sinAngle
        let targetWeight = sin(clampedProgress * angle) / sinAngle
        let blended = fromVector * startWeight + toVector * targetWeight
        return coordinate(for: blended)
    }

    /// Central angle of the arc, in radians.
    static func centralAngle(from start: GeoCoordinate, to target: GeoCoordinate) -> Double {
        centralAngle(fromVector: unitVector(for: start), toVector: unitVector(for: target))
    }

    /// Forward azimuth at `start`, clockwise from north, in degrees `[0, 360)`.
    /// Degenerate (identical or antipodal endpoints) returns 0.
    static func bearingDegrees(from start: GeoCoordinate, to target: GeoCoordinate) -> Double {
        let startLatitude = start.latitude * .pi / 180.0
        let targetLatitude = target.latitude * .pi / 180.0
        let longitudeDelta = (target.longitude - start.longitude) * .pi / 180.0

        let y = sin(longitudeDelta) * cos(targetLatitude)
        let x = cos(startLatitude) * sin(targetLatitude)
            - sin(startLatitude) * cos(targetLatitude) * cos(longitudeDelta)
        guard x != 0 || y != 0 else { return 0 }

        let bearing = atan2(y, x) * 180.0 / .pi
        return (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    /// Unit vector in the (x = cosLat*cosLon, y = cosLat*sinLon, z = sinLat)
    /// frame. Not the globe shader frame of `GeoProjectionBasis.sphereUnit`:
    /// this one only ever round-trips through `coordinate(for:)`.
    static func unitVector(for coordinate: GeoCoordinate) -> SIMD3<Double> {
        let latitude = coordinate.latitude * .pi / 180.0
        let longitude = coordinate.longitude * .pi / 180.0
        let cosLatitude = cos(latitude)
        return SIMD3<Double>(cosLatitude * cos(longitude),
                             cosLatitude * sin(longitude),
                             sin(latitude))
    }

    /// Half-chord form: accurate for the whole `[0, pi]` range, unlike
    /// `acos(dot)`, which loses all precision for short arcs.
    static func centralAngle(fromVector: SIMD3<Double>, toVector: SIMD3<Double>) -> Double {
        let chord = simd_length(fromVector - toVector)
        let opposite = simd_length(fromVector + toVector)
        return 2.0 * atan2(chord, opposite)
    }

    static func coordinate(for vector: SIMD3<Double>) -> GeoCoordinate {
        let normalized = simd_normalize(vector)
        let latitude = atan2(normalized.z,
                             sqrt(normalized.x * normalized.x + normalized.y * normalized.y))
        let longitude = atan2(normalized.y, normalized.x)
        return GeoCoordinate(latitude: latitude * 180.0 / .pi,
                             longitude: longitude * 180.0 / .pi)
    }

    static func normalizedLongitude(_ longitude: Double) -> Double {
        var normalized = longitude.truncatingRemainder(dividingBy: 360)
        if normalized > 180 {
            normalized -= 360
        } else if normalized < -180 {
            normalized += 360
        }
        return normalized
    }

    /// Antipodal endpoints leave the great circle underdetermined; fall back
    /// to a lat/lon lerp along the shortest longitude delta.
    private static func antipodalCoordinate(from start: GeoCoordinate,
                                            to target: GeoCoordinate,
                                            progress: Double) -> GeoCoordinate {
        let latitude = start.latitude + (target.latitude - start.latitude) * progress
        let longitudeDelta = shortestLongitudeDelta(from: start.longitude, to: target.longitude)
        let longitude = normalizedLongitude(start.longitude + longitudeDelta * progress)
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func shortestLongitudeDelta(from start: Double, to target: Double) -> Double {
        var delta = normalizedLongitude(target) - normalizedLongitude(start)
        if delta > 180 {
            delta -= 360
        } else if delta < -180 {
            delta += 360
        }
        return delta
    }
}
