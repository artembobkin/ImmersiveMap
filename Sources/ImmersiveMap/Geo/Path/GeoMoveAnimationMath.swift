// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// The timing of something that moves from one place on the map to another
/// (a pin, a scene model): how long the move takes and how it eases. The
/// path itself is the great circle (`GeoGreatCircleMath.coordinate`).
enum GeoMoveAnimationMath {
    static let minimumDuration: TimeInterval = 0.14
    static let maximumDuration: TimeInterval = 0.60
    static let saturationDistanceMeters: Double = 250.0
    static let minimumAnimatedDistanceMeters: Double = 0.01

    /// Move duration scaled by geodesic distance: short hops stay snappy,
    /// long jumps saturate instead of dragging on. Zero for a move too
    /// short to animate.
    static func duration(from start: GeoCoordinate,
                         to target: GeoCoordinate) -> TimeInterval {
        let distance = geodesicDistanceMeters(from: start, to: target)
        guard distance > minimumAnimatedDistanceMeters else {
            return 0
        }

        let normalized = min(max(distance / saturationDistanceMeters, 0), 1)
        let eased = pow(normalized, 0.6)
        return minimumDuration + (maximumDuration - minimumDuration) * eased
    }

    /// Cubic ease-out: fast at the start, settling into the end.
    static func easedProgress(for rawProgress: Double) -> Double {
        let clamped = min(max(rawProgress, 0), 1)
        let inverse = 1 - clamped
        return 1 - inverse * inverse * inverse
    }

    /// The distance between two places over a sphere of the Earth's mean
    /// radius (the haversine formula).
    static func geodesicDistanceMeters(from start: GeoCoordinate,
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
