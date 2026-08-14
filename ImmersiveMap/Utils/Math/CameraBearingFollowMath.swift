// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Stateless math for time-normalized smoothing of camera bearing toward a target value.
/// Unlike pitch, bearing is cyclic: the settle follows the shortest angular path (through 180°)
/// unless a bearing cap forbids that path, and the gap decays exponentially by half-life, so the
/// per-frame step depends on time rather than on the uneven event rate of the slider/gesture.
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

    /// The angular gap the follow eases across. The shortest path is right for
    /// an unbounded compass, but under a bearing cap wider than a quarter turn
    /// the shortest path between two legal bearings can run behind the compass
    /// through the forbidden arc: each eased step is then clamped back to one
    /// cap edge and the follow stalls there instead of arriving. Between two
    /// bearings inside the cap the plain difference of the normalized angles is
    /// the monotone in-window path, so under a cap that is the one to ease.
    static func followDelta(current: Float,
                            target: Float,
                            maximumAbsoluteBearing: Float) -> Float {
        guard maximumAbsoluteBearing < .pi else {
            return shortestDelta(current: current, target: target)
        }

        return normalized(target) - normalized(current)
    }

    /// Normalizes an angle to (-pi, pi].
    static func normalized(_ bearing: Float) -> Float {
        let twoPi = Float.pi * 2
        var value = bearing.truncatingRemainder(dividingBy: twoPi)
        if value > .pi {
            value -= twoPi
        } else if value <= -.pi {
            value += twoPi
        }
        return value
    }

    /// New bearing per frame: the remaining gap to the target is multiplied by the half-life factor.
    static func steppedBearing(current: Float,
                               target: Float,
                               deltaTime: CFTimeInterval,
                               halfLife: Double,
                               maximumAbsoluteBearing: Float) -> Float {
        let sanitizedHalfLife = max(0.001, halfLife.isFinite ? halfLife : 0.001)
        let factor = Float(exp(-log(2.0) * deltaTime / sanitizedHalfLife))
        let delta = followDelta(current: current,
                                target: target,
                                maximumAbsoluteBearing: maximumAbsoluteBearing)
        return current + delta * (1 - factor)
    }

    static func shouldSnap(current: Float, target: Float) -> Bool {
        abs(shortestDelta(current: current, target: target)) <= snapThreshold
    }

    /// true if the bearing is stuck (hit a constraint at its limit): no progress between frames,
    /// yet the target is not reached; the follow must stop instead of spinning the display link forever.
    static func isStalled(current: Float, previous: Float, target: Float) -> Bool {
        abs(shortestDelta(current: previous, target: current)) <= progressThreshold
            && abs(shortestDelta(current: current, target: target)) > snapThreshold
    }
}
