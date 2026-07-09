// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Stateless-математика time-normalized сглаживания camera bearing к целевому значению.
/// В отличие от pitch, bearing цикличен: доводка идет по кратчайшему угловому пути (через 180°),
/// а гэп затухает экспоненциально по half-life, поэтому шаг на кадр зависит от времени, а не от
/// неравномерной частоты событий слайдера/жеста.
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

    /// Кратчайшая угловая разница target-current, приведенная к [-pi, pi].
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

    /// Новый bearing на кадр: остаток кратчайшего гэпа до цели домножается на half-life factor.
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

    /// true, если bearing застрял (уперся в constraint у предела): прогресса между кадрами нет,
    /// но цель не достигнута — follow надо остановить, а не крутить display link бесконечно.
    static func isStalled(current: Float, previous: Float, target: Float) -> Bool {
        abs(shortestDelta(current: previous, target: current)) <= progressThreshold
            && abs(shortestDelta(current: current, target: target)) > snapThreshold
    }
}
