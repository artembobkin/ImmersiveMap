// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Deterministic animation math for scene models: move durations, quaternion
/// orientation, and scalar easing. Kept inside SceneModels so the domain folder
/// does not depend on Avatars. Great-circle interpolation itself lives in
/// `GeoGreatCircleMath`, shared with route tessellation.
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

    /// Inverse of `orientationQuaternion`: recovers heading, pitch and roll from
    /// an orientation in the anchor's tangent frame. Needed to tell the
    /// controller where a path animation left a model, since the store carries
    /// the displayed orientation as a quaternion.
    static func orientationAngles(of orientation: simd_quatf)
        -> (headingDegrees: Double, pitchDegrees: Double, rollDegrees: Double) {
        let matrix = simd_float3x3(orientation)
        // Rz(-heading) * Rx(pitch) * Ry(roll), so row 2 column 1 is sin(pitch).
        let sinPitch = min(max(matrix.columns.1[2], -1), 1)
        let pitch = asin(sinPitch)
        let cosPitch = sqrt(max(0, 1 - sinPitch * sinPitch))

        let heading: Float
        let roll: Float
        if cosPitch > 1e-5 {
            heading = -atan2(-matrix.columns.1[0], matrix.columns.1[1])
            roll = atan2(-matrix.columns.0[2], matrix.columns.2[2])
        } else {
            // Gimbal lock at +-90 degrees of pitch: heading and roll turn about
            // the same axis, so the whole turn is reported as heading.
            heading = -atan2(matrix.columns.0[1], matrix.columns.0[0])
            roll = 0
        }

        let degrees = 180.0 / Double.pi
        return (Double(heading) * degrees, Double(pitch) * degrees, Double(roll) * degrees)
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

}
