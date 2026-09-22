// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Stateless math for time-normalized smoothing of camera pitch toward a target value.
/// The gap between the current and target pitch decays exponentially by half-life, so the
/// per-frame step depends on elapsed time rather than the uneven rate of touch events.
enum CameraPitchFollowMath {
    /// Maximum dt between ticks (guards against a jump after a pause/backgrounding).
    static let maximumDeltaTime: CFTimeInterval = 0.05

    /// Threshold in radians below which pitch is considered to have reached the target and follow is released.
    static let snapThreshold: Float = 0.0003

    /// No-progress threshold: if the actual pitch did not move between frames (hit a
    /// clamp/ceiling) while the target is still far away, follow must stop rather than spin forever.
    static let progressThreshold: Float = 0.00002

    static func clampedDeltaTime(_ deltaTime: CFTimeInterval) -> CFTimeInterval {
        guard deltaTime.isFinite else {
            return 0
        }

        return min(max(0, deltaTime), maximumDeltaTime)
    }

    /// New pitch for the frame: the remaining gap to the target is multiplied by the half-life factor.
    static func steppedPitch(current: Float,
                             target: Float,
                             deltaTime: CFTimeInterval,
                             halfLife: Double) -> Float {
        let sanitizedHalfLife = max(0.001, halfLife.isFinite ? halfLife : 0.001)
        let factor = Float(exp(-log(2.0) * deltaTime / sanitizedHalfLife))
        return target - (target - current) * factor
    }

    static func shouldSnap(current: Float, target: Float) -> Bool {
        abs(target - current) <= snapThreshold
    }

    /// true if the actual pitch is stuck (hit the clamp at the ceiling): no progress between
    /// frames but the target is not reached. Needed so follow does not spin the display link forever.
    static func isStalled(current: Float, previous: Float, target: Float) -> Bool {
        abs(current - previous) <= progressThreshold && abs(target - current) > snapThreshold
    }
}
