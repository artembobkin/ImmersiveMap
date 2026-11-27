// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Deterministic animation math for scene models: quaternion orientation
/// and scalar interpolation. The timing of a move is `GeoMoveAnimationMath`
/// and the great-circle interpolation `GeoGreatCircleMath`, shared with the
/// pins.
enum SceneModelAnimationMath {
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
}
