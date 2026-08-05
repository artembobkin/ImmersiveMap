// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One point of a path resolved for rendering or for placing a model: where it
/// is, how high, how far along, and which way the trajectory points there.
struct GeoPathSample: Equatable {
    let coordinate: GeoCoordinate
    /// Cached projection trigonometry, so the per-frame world build stays
    /// linear algebra.
    let basis: GeoProjectionBasis
    let altitudeMeters: Double
    /// Position along the path by arc length, `0...1`.
    let fraction: Double
    /// Course of the trajectory, clockwise from north, in degrees.
    let headingDegrees: Double
    /// Climb angle of the altitude profile, in degrees; positive is nose up.
    let pitchDegrees: Double
}

/// Arc-length geometry derived from a path once: cleaned waypoints, per-segment
/// central angles and their running sums. Building it is the only place that
/// walks the waypoint list, so both the ribbon tessellation and the per-frame
/// model position resolve a fraction the same way.
struct GeoPathMetrics {
    /// About 27.8 km of ground per step. The globe presentation ends near zoom
    /// 7, where one pixel is roughly 611 meters, and the chord sagitta of a
    /// 0.25 degree step is about 15 meters, that is 0.025 pixels. Two orders of
    /// margin, and a pole-to-pole path still fits in 721 samples.
    static let angularStepRadians = 0.25 * Double.pi / 180.0
    static let maximumSampleCount = 2048
    private static let degenerateSegmentAngleRadians = 1e-9

    private static let groundRadiusMeters = ImmersiveMapProjection.earthCircumferenceMeters / (2.0 * Double.pi)

    let path: ImmersiveMapGeoPath
    /// Waypoints with zero-length segments removed; at least two entries.
    let waypoints: [GeoCoordinate]
    /// Central angle of every segment, `waypoints.count - 1` entries.
    let segmentAngles: [Double]
    /// Running sums of `segmentAngles`, `waypoints.count` entries starting at 0.
    let cumulativeAngles: [Double]
    let totalAngleRadians: Double

    /// nil when the path cannot describe a trajectory: fewer than two distinct
    /// waypoints, or every point coincident.
    init?(path: ImmersiveMapGeoPath) {
        var waypoints: [GeoCoordinate] = []
        var segmentAngles: [Double] = []
        var cumulativeAngles: [Double] = []
        var runningAngle: Double = 0

        for waypoint in path.waypoints {
            guard let previous = waypoints.last else {
                waypoints.append(waypoint)
                cumulativeAngles.append(0)
                continue
            }
            let angle = GeoGreatCircleMath.centralAngle(from: previous, to: waypoint)
            guard angle > Self.degenerateSegmentAngleRadians else { continue }
            runningAngle += angle
            waypoints.append(waypoint)
            segmentAngles.append(angle)
            cumulativeAngles.append(runningAngle)
        }

        guard waypoints.count >= 2, runningAngle > 0 else { return nil }

        self.path = path
        self.waypoints = waypoints
        self.segmentAngles = segmentAngles
        self.cumulativeAngles = cumulativeAngles
        totalAngleRadians = runningAngle
    }

    /// Number of samples the ribbon is tessellated into.
    var sampleCount: Int {
        let stepped = Int(ceil(totalAngleRadians / Self.angularStepRadians)) + 1
        return min(max(stepped, 2), Self.maximumSampleCount)
    }

    /// Half a sample step: the arm of the central difference used for heading
    /// and pitch, shared by the ribbon and the animated model so both agree.
    var derivativeFraction: Double {
        0.5 / Double(sampleCount - 1)
    }

    func coordinate(atFraction fraction: Double) -> GeoCoordinate {
        let clamped = min(max(fraction, 0), 1)
        let targetAngle = clamped * totalAngleRadians
        let segment = segmentIndex(forAngle: targetAngle)
        return coordinate(inSegment: segment, targetAngle: targetAngle)
    }

    func sample(atFraction fraction: Double) -> GeoPathSample {
        let clamped = min(max(fraction, 0), 1)
        let targetAngle = clamped * totalAngleRadians
        return sample(atFraction: clamped,
                      targetAngle: targetAngle,
                      segment: segmentIndex(forAngle: targetAngle))
    }

    /// Every sample of the tessellated path, ordered from fraction 0 to 1.
    func samples() -> [GeoPathSample] {
        let count = sampleCount
        var result: [GeoPathSample] = []
        result.reserveCapacity(count)

        var segment = 0
        for index in 0..<count {
            let fraction = Double(index) / Double(count - 1)
            let targetAngle = fraction * totalAngleRadians
            segment = segmentIndex(forAngle: targetAngle, startingAt: segment)
            result.append(sample(atFraction: fraction, targetAngle: targetAngle, segment: segment))
        }
        return result
    }

    private func sample(atFraction fraction: Double,
                        targetAngle: Double,
                        segment: Int) -> GeoPathSample {
        let coordinate = coordinate(inSegment: segment, targetAngle: targetAngle)
        let delta = derivativeFraction
        let before = max(0, fraction - delta)
        let after = min(1, fraction + delta)
        let heading = GeoGreatCircleMath.bearingDegrees(from: self.coordinate(atFraction: before),
                                                        to: self.coordinate(atFraction: after))

        let groundDistance = (after - before) * totalAngleRadians * Self.groundRadiusMeters
        let altitudeDelta = path.altitudeMeters(atFraction: after) - path.altitudeMeters(atFraction: before)
        let pitch = groundDistance > 0
            ? atan2(altitudeDelta, groundDistance) * 180.0 / .pi
            : 0

        return GeoPathSample(coordinate: coordinate,
                             basis: GeoProjectionBasis(coordinate: coordinate),
                             altitudeMeters: path.altitudeMeters(atFraction: fraction),
                             fraction: fraction,
                             headingDegrees: heading,
                             pitchDegrees: pitch)
    }

    private func coordinate(inSegment segment: Int, targetAngle: Double) -> GeoCoordinate {
        let segmentAngle = segmentAngles[segment]
        let localProgress = segmentAngle > 0
            ? (targetAngle - cumulativeAngles[segment]) / segmentAngle
            : 0
        return GeoGreatCircleMath.coordinate(from: waypoints[segment],
                                             to: waypoints[segment + 1],
                                             progress: localProgress)
    }

    /// Index of the segment containing `targetAngle`. `startingAt` lets a
    /// sequential walk stay linear instead of rescanning from the beginning.
    private func segmentIndex(forAngle targetAngle: Double, startingAt start: Int = 0) -> Int {
        var index = min(max(start, 0), segmentAngles.count - 1)
        while index + 1 < segmentAngles.count, targetAngle > cumulativeAngles[index + 1] {
            index += 1
        }
        return index
    }
}

/// Entry points that build metrics on demand. Callers that resolve a path every
/// frame should keep the `GeoPathMetrics` instead.
enum GeoPathSampler {
    static func samples(for path: ImmersiveMapGeoPath) -> [GeoPathSample] {
        GeoPathMetrics(path: path)?.samples() ?? []
    }

    static func sample(for path: ImmersiveMapGeoPath, fraction: Double) -> GeoPathSample? {
        GeoPathMetrics(path: path)?.sample(atFraction: fraction)
    }
}
