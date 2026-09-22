// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import QuartzCore
import simd

/// Stateless math for a camera chasing a point that moves along a path.
///
/// Unlike the pitch and bearing followers, the target here never stops moving,
/// so there is no snap or stall termination: the traversal ends on its own when
/// the duration runs out. The catch-up is the same time-normalized exponential
/// decay, which keeps the step independent of the frame rate.
enum CameraPathFollowMath {
    /// A frame longer than this (a stall, a resumed park) must not teleport the
    /// camera; the step is capped instead.
    static let maximumDeltaTime: CFTimeInterval = 0.05

    static func clampedDeltaTime(_ deltaTime: CFTimeInterval) -> CFTimeInterval {
        guard deltaTime.isFinite else { return 0 }
        return min(max(0, deltaTime), maximumDeltaTime)
    }

    /// Fraction of the remaining gap closed in one step of `deltaTime`.
    /// A non-positive half-life pins the camera rigidly to the target.
    ///
    /// `capsDeltaTime: false` is for the frame that ends a traversal: capping
    /// there would leave the camera stranded wherever a stalled display link
    /// happened to drop it, while reporting that the traversal succeeded. The
    /// uncapped step owes exactly the catch-up the stall skipped.
    static func catchUpFraction(deltaTime: CFTimeInterval,
                                halfLife: Double,
                                capsDeltaTime: Bool = true) -> Double {
        guard halfLife.isFinite, halfLife > 0 else { return 1 }
        let step = capsDeltaTime ? clampedDeltaTime(deltaTime) : max(0, deltaTime.isFinite ? deltaTime : 0)
        return 1 - exp(-log(2.0) * step / halfLife)
    }

    /// Shortest signed delta in normalized world X, where 1 is a whole world:
    /// a camera near the antimeridian must chase across the seam, not the long
    /// way around the globe.
    static func shortestNormalizedWorldXDelta(current: Double, target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 1)
        if delta > 0.5 {
            delta -= 1
        } else if delta < -0.5 {
            delta += 1
        }
        return delta
    }

    /// Steps the camera center toward the target in normalized world mercator.
    /// X takes the shortest way around the seam and stays wrapped; Y is a plain
    /// decay, since Mercator Y does not wrap.
    static func steppedCenter(current: SIMD2<Double>,
                              target: SIMD2<Double>,
                              catchUpFraction: Double) -> SIMD2<Double> {
        let fraction = min(max(catchUpFraction, 0), 1)
        let deltaX = shortestNormalizedWorldXDelta(current: current.x, target: target.x)
        let x = ImmersiveMapProjection.wrapNormalizedWorldX(current.x + deltaX * fraction)
        let y = ImmersiveMapProjection.clampNormalizedWorldY(current.y + (target.y - current.y) * fraction)
        return SIMD2<Double>(x, y)
    }

    /// Steps a scalar (zoom, pitch) toward its target with the same decay.
    static func steppedScalar(current: Double, target: Double, catchUpFraction: Double) -> Double {
        let fraction = min(max(catchUpFraction, 0), 1)
        return current + (target - current) * fraction
    }

    /// World-mercator center of a coordinate, the space the camera state uses.
    static func centerWorldMercator(of coordinate: GeoCoordinate) -> SIMD2<Double> {
        ImmersiveMapProjection.worldMercator(latitude: coordinate.latitude * .pi / 180.0,
                                             longitude: coordinate.longitude * .pi / 180.0)
    }
}
