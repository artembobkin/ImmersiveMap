// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Stateless math for time-normalized smoothing of camera bearing toward a target value.
/// Unlike pitch, bearing is cyclic: the settle follows the shortest angular path (through 180°),
/// and the gap decays exponentially by half-life, so the per-frame step depends on time rather
/// than on the uneven event rate of the slider/gesture.
enum CameraBearingFollowMath {
    static let maximumDeltaTime: CFTimeInterval = 0.05
    static let snapThreshold: Float = 0.0003
    static let progressThreshold: Float = 0.00002

    static func clampedDeltaTime(_ deltaTime: CFTimeInterval) -> CFTimeInterval {
        guard deltaTime.isFinite else {
            return 0
        }

        return min(max(0, deltaTime), maximumDeltaTime)
    }

    /// Shortest angular difference target-current, normalized to [-pi, pi].
    static func shortestDelta(current: Float, target: Float) -> Float {
        let twoPi = Float.pi * 2
        var delta = (target - current).truncatingRemainder(dividingBy: twoPi)
        if delta > .pi {
            delta -= twoPi
        } else if delta < -.pi {
            delta += twoPi
        }
        return delta
    }

    /// New bearing per frame: the remaining shortest gap to the target is multiplied by the half-life factor.
    static func steppedBearing(current: Float,
                               target: Float,
                               deltaTime: CFTimeInterval,
                               halfLife: Double) -> Float {
        let sanitizedHalfLife = max(0.001, halfLife.isFinite ? halfLife : 0.001)
        let factor = Float(exp(-log(2.0) * deltaTime / sanitizedHalfLife))
        return current + shortestDelta(current: current, target: target) * (1 - factor)
    }

    static func shouldSnap(current: Float, target: Float) -> Bool {
        abs(shortestDelta(current: current, target: target)) <= snapThreshold
    }

    /// true if the bearing is stuck (hit a constraint at its limit): no progress between frames,
    /// yet the target is not reached — the follow must stop instead of spinning the display link forever.
    static func isStalled(current: Float, previous: Float, target: Float) -> Bool {
        abs(shortestDelta(current: previous, target: current)) <= progressThreshold
            && abs(shortestDelta(current: current, target: target)) > snapThreshold
    }
}
