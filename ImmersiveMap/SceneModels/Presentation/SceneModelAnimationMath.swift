// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Deterministic animation math for scene models: great-circle position
/// interpolation, quaternion orientation, and scalar easing. Kept inside
/// SceneModels so the domain folder does not depend on Avatars.
enum SceneModelAnimationMath {
    static let minimumPositionDuration: TimeInterval = 0.14
    static let maximumPositionDuration: TimeInterval = 0.60
    static let saturationDistanceMeters: Double = 250.0
    static let minimumAnimatedDistanceMeters: Double = 0.01

    /// Move duration scaled by geodesic distance: short hops stay snappy,
    /// long jumps saturate instead of dragging on.
    static func positionAnimationDuration(from start: GeoCoordinate,
                                          to target: GeoCoordinate) -> TimeInterval {
        let distance = geodesicDistanceMeters(from: start, to: target)
        guard distance > minimumAnimatedDistanceMeters else {
            return 0
        }

        let normalized = min(max(distance / saturationDistanceMeters, 0), 1)
        let eased = pow(normalized, 0.6)
        return minimumPositionDuration + (maximumPositionDuration - minimumPositionDuration) * eased
    }

    /// Great-circle interpolation over unit vectors: correct near the
    /// antimeridian and the poles, unlike lat/lon lerp.
    static func coordinate(from start: GeoCoordinate,
                           to target: GeoCoordinate,
                           progress: Double) -> GeoCoordinate {
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else { return start }
        guard clampedProgress < 1 else { return target }

        let fromVector = unitVector(for: start)
        let toVector = unitVector(for: target)
        let dotProduct = min(max(simd_dot(fromVector, toVector), Float(-1)), Float(1))
        if dotProduct > 0.9995 {
            let blended = simd_normalize(fromVector + (toVector - fromVector) * Float(clampedProgress))
            return coordinate(for: blended)
        }
        if dotProduct < -0.9995 {
            return fallbackCoordinate(from: start, to: target, progress: clampedProgress)
        }

        let angle = acos(Double(dotProduct))
        let sinAngle = sin(angle)
        guard sinAngle > Double.leastNonzeroMagnitude else {
            return target
        }

        let startWeight = sin((1 - clampedProgress) * angle) / sinAngle
        let targetWeight = sin(clampedProgress * angle) / sinAngle
        let blended = simd_normalize(fromVector * Float(startWeight) + toVector * Float(targetWeight))
        return coordinate(for: blended)
    }

    static func easedProgress(for rawProgress: Double) -> Double {
        let clamped = min(max(rawProgress, 0), 1)
        let inverse = 1 - clamped
        return 1 - inverse * inverse * inverse
    }

    /// Orientation in the anchor's tangent frame (east = +X, north = +Y,
    /// up = +Z): heading is clockwise from north about up, then pitch about
    /// east, then roll about the model's forward axis. Matches the matrix
    /// product Rz(-heading) * Rx(pitch) * Ry(roll).
    static func orientationQuaternion(headingDegrees: Double,
                                      pitchDegrees: Double,
                                      rollDegrees: Double) -> simd_quatf {
        let heading = simd_quatf(angle: -Float(headingDegrees * .pi / 180.0),
                                 axis: SIMD3<Float>(0, 0, 1))
        let pitch = simd_quatf(angle: Float(pitchDegrees * .pi / 180.0),
                               axis: SIMD3<Float>(1, 0, 0))
        let roll = simd_quatf(angle: Float(rollDegrees * .pi / 180.0),
                              axis: SIMD3<Float>(0, 1, 0))
        return heading * pitch * roll
    }

    /// Shortest-arc quaternion interpolation.
    static func orientation(from start: simd_quatf,
                            to target: simd_quatf,
                            progress: Double) -> simd_quatf {
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else { return start }
        guard clampedProgress < 1 else { return target }
        return simd_slerp(start, target, Float(clampedProgress))
    }

    static func scalar(from start: Double,
                       to target: Double,
                       progress: Double) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        return start + (target - start) * clampedProgress
    }

    private static func geodesicDistanceMeters(from start: GeoCoordinate,
                                               to target: GeoCoordinate) -> Double {
        let latitude1 = start.latitude * .pi / 180.0
        let latitude2 = target.latitude * .pi / 180.0
        let latitudeDelta = latitude2 - latitude1
        let longitudeDelta = (target.longitude - start.longitude) * .pi / 180.0
        let sinLatitude = sin(latitudeDelta * 0.5)
        let sinLongitude = sin(longitudeDelta * 0.5)
        let a = sinLatitude * sinLatitude
            + cos(latitude1) * cos(latitude2) * sinLongitude * sinLongitude
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return 6_371_000.0 * c
    }

    private static func unitVector(for coordinate: GeoCoordinate) -> SIMD3<Float> {
        let latitude = coordinate.latitude * .pi / 180.0
        let longitude = coordinate.longitude * .pi / 180.0
        let cosLatitude = cos(latitude)
        return SIMD3<Float>(Float(cosLatitude * cos(longitude)),
                            Float(cosLatitude * sin(longitude)),
                            Float(sin(latitude)))
    }

    private static func coordinate(for vector: SIMD3<Float>) -> GeoCoordinate {
        let normalized = simd_normalize(vector)
        let latitude = atan2(Double(normalized.z),
                             sqrt(Double(normalized.x * normalized.x + normalized.y * normalized.y)))
        let longitude = atan2(Double(normalized.y), Double(normalized.x))
        return GeoCoordinate(latitude: latitude * 180.0 / .pi,
                             longitude: longitude * 180.0 / .pi)
    }

    /// Antipodal endpoints leave the great circle underdetermined; fall back
    /// to a lat/lon lerp along the shortest longitude delta.
    private static func fallbackCoordinate(from start: GeoCoordinate,
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

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var normalized = longitude.truncatingRemainder(dividingBy: 360)
        if normalized > 180 {
            normalized -= 360
        } else if normalized < -180 {
            normalized += 360
        }
        return normalized
    }
}
