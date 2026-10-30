// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import Foundation
import simd

/// The geometry of the debug panel's sun picker: the sky seen from above
/// as a disc and from the side as a quarter circle.
///
/// The disc turns with the camera: up is the direction the camera looks
/// in, so a sun dragged to the top shines from in front of the view and
/// one dragged to the bottom from behind it. The sun itself stays where
/// the world puts it (`SceneLightSettings.direction`): the disc only reads
/// and sets it from the view. The direction from the centre is the sun's
/// azimuth, the distance its elevation, the zenith at the centre and the
/// horizon on the rim, at an even step of degrees. The side view is the
/// elevation alone, the horizon to the right and the zenith straight up.
enum DebugOverlaySunDial {
    /// The compass direction the camera looks in, in degrees clockwise
    /// from north, 0 to 360: the camera turned by `bearingRadians` sees
    /// the world rotated by it (`ZoomAnchorMath`), so its view is the
    /// bearing's opposite turn.
    static func viewAzimuthDegrees(bearingRadians: Double) -> Double {
        normalized(-bearingRadians * 180 / .pi)
    }

    /// Where a sun stands in the disc, in its unit radius with y up, seen
    /// from a camera looking at `viewAzimuthDegrees`.
    static func point(azimuthDegrees: Double, elevationDegrees: Double, viewAzimuthDegrees: Double) -> SIMD2<Double> {
        let relative = (azimuthDegrees - viewAzimuthDegrees) * .pi / 180
        let radius = (90 - min(max(elevationDegrees, 0), 90)) / 90
        return SIMD2<Double>(radius * sin(relative), radius * cos(relative))
    }

    /// The sun at a point of the disc, the inverse of `point`: the rim and
    /// past it is the horizon, and the elevation keeps to `elevationRange`.
    /// At the very centre the direction is undefined and `azimuthDegrees`
    /// is kept.
    static func angles(point: SIMD2<Double>,
                       viewAzimuthDegrees: Double,
                       azimuthDegrees: Double,
                       elevationRange: ClosedRange<Double>) -> (azimuthDegrees: Double, elevationDegrees: Double) {
        let radius = min(simd_length(point), 1)
        let azimuth = radius > 1e-6
            ? normalized(viewAzimuthDegrees + atan2(point.x, point.y) * 180 / .pi)
            : azimuthDegrees
        let elevation = min(max(90 - radius * 90, elevationRange.lowerBound), elevationRange.upperBound)
        return (azimuth, elevation)
    }

    /// The elevation at a point of the side view, from the ground's point
    /// at the origin, y up: the angle of the point over the horizon,
    /// either side of the origin, kept to `elevationRange`.
    static func elevation(sidePoint point: SIMD2<Double>, elevationRange: ClosedRange<Double>) -> Double {
        let degrees = atan2(max(point.y, 0), abs(point.x)) * 180 / .pi
        return min(max(degrees, elevationRange.lowerBound), elevationRange.upperBound)
    }

    private static func normalized(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        // Plus zero: a negative zero would read "-0°".
        return wrapped < 0 ? wrapped + 360 : wrapped + 0
    }
}
