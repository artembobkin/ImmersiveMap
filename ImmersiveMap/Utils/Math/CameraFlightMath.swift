// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

enum CameraFlightMath {
    static let minimumDuration: TimeInterval = 0.001
    private static let deltaEpsilon = 1e-9
    private static let greatCircleAngleEpsilon = 1e-6

    static func easeInOutCubic(_ progress: Double) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        if clampedProgress < 0.5 {
            return 4 * clampedProgress * clampedProgress * clampedProgress
        }

        let invertedProgress = -2 * clampedProgress + 2
        return 1 - (invertedProgress * invertedProgress * invertedProgress) / 2
    }

    static func shortestWrappedWorldDelta(from start: Double,
                                          to end: Double) -> Double {
        var delta = end - start
        if delta > 0.5 {
            delta -= 1.0
        } else if delta < -0.5 {
            delta += 1.0
        }
        return delta
    }

    static func interpolateWrappedWorldX(from start: Double,
                                         to end: Double,
                                         progress: Double) -> Double {
        ImmersiveMapProjection.wrapNormalizedWorldX(start + shortestWrappedWorldDelta(from: start, to: end) * progress)
    }

    static func shortestBearingDelta(from start: Float,
                                     to end: Float) -> Float {
        let normalizedStart = CameraBearingConstraintResolver.normalized(start)
        let normalizedEnd = CameraBearingConstraintResolver.normalized(end)
        var delta = normalizedEnd - normalizedStart
        if delta > .pi {
            delta -= 2 * .pi
        } else if delta < -.pi {
            delta += 2 * .pi
        }
        return delta
    }

    static func interpolateBearing(from start: Float,
                                   to end: Float,
                                   progress: Double) -> Float {
        let normalizedStart = CameraBearingConstraintResolver.normalized(start)
        let delta = shortestBearingDelta(from: start, to: end)
        return CameraBearingConstraintResolver.normalized(normalizedStart + delta * Float(progress))
    }

    static func hasMeaningfulDelta(from start: ImmersiveMapCameraState,
                                   to end: ImmersiveMapCameraState) -> Bool {
        abs(shortestWrappedWorldDelta(from: start.centerWorldMercator.x, to: end.centerWorldMercator.x)) > deltaEpsilon
            || abs(end.centerWorldMercator.y - start.centerWorldMercator.y) > deltaEpsilon
            || abs(end.zoom - start.zoom) > deltaEpsilon
            || abs(shortestBearingDelta(from: start.bearing, to: end.bearing)) > Float(deltaEpsilon)
            || abs(end.pitch - start.pitch) > Float(deltaEpsilon)
    }

    static func mercatorCenter(from start: SIMD2<Double>,
                               to end: SIMD2<Double>,
                               progress: Double) -> SIMD2<Double> {
        SIMD2<Double>(interpolateWrappedWorldX(from: start.x, to: end.x, progress: progress),
                      start.y + (end.y - start.y) * progress)
    }

    static func interpolatedZoom(from startState: ImmersiveMapCameraState,
                                 to targetState: ImmersiveMapCameraState,
                                 rawProgress: Double,
                                 easedProgress: Double,
                                 altitudeStyle: CameraFlightAltitudeStyle) -> Double {
        switch altitudeStyle {
        case .direct:
            return startState.zoom + (targetState.zoom - startState.zoom) * easedProgress
        case .overviewFirst:
            let clampedProgress = min(max(rawProgress, 0), 1)
            let delayedZoomProgress = clampedProgress
                * clampedProgress
                * clampedProgress
                * clampedProgress
                * clampedProgress
                * clampedProgress
            return startState.zoom + (targetState.zoom - startState.zoom) * delayedZoomProgress
        }
    }

    static func greatCircleCenter(from start: SIMD2<Double>,
                                  to end: SIMD2<Double>,
                                  progress: Double) -> SIMD2<Double>? {
        let startLatitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: start.y)
        let startLongitude = ImmersiveMapProjection.longitude(fromNormalizedWorldX: start.x)
        let endLatitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: end.y)
        let endLongitude = ImmersiveMapProjection.longitude(fromNormalizedWorldX: end.x)

        let startVector = normalizedCartesian(latitudeRadians: startLatitude,
                                              longitudeRadians: startLongitude)
        let endVector = normalizedCartesian(latitudeRadians: endLatitude,
                                            longitudeRadians: endLongitude)

        let dotProduct = min(1.0, max(-1.0, simd_dot(startVector, endVector)))
        let angle = acos(dotProduct)
        let interpolatedVector: SIMD3<Double>
        if angle < greatCircleAngleEpsilon {
            interpolatedVector = simd_normalize(startVector + (endVector - startVector) * progress)
        } else if abs(.pi - angle) < greatCircleAngleEpsilon {
            return nil
        } else {
            let sinAngle = sin(angle)
            guard abs(sinAngle) >= greatCircleAngleEpsilon else {
                return nil
            }

            let startWeight = sin((1 - progress) * angle) / sinAngle
            let endWeight = sin(progress * angle) / sinAngle
            interpolatedVector = simd_normalize(startVector * startWeight + endVector * endWeight)
        }

        let latitude = asin(max(-1.0, min(1.0, interpolatedVector.z)))
        let longitude = atan2(interpolatedVector.y, interpolatedVector.x)
        return ImmersiveMapProjection.worldMercator(latitude: latitude,
                                                    longitude: longitude)
    }

    private static func normalizedCartesian(latitudeRadians latitude: Double,
                                            longitudeRadians longitude: Double) -> SIMD3<Double> {
        let cosLatitude = cos(latitude)
        return simd_normalize(
            SIMD3<Double>(cosLatitude * cos(longitude),
                          cosLatitude * sin(longitude),
                          sin(latitude))
        )
    }
}
