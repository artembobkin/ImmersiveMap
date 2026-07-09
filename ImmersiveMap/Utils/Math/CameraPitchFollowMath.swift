// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Stateless-математика time-normalized сглаживания camera pitch к целевому значению.
/// Гэп между текущим и целевым pitch затухает экспоненциально по half-life, поэтому шаг
/// на кадр зависит от прошедшего времени, а не от неравномерной частоты touch-событий.
enum CameraPitchFollowMath {
    /// Максимальный dt между тиками (страховка от скачка после паузы/ухода в фон).
    static let maximumDeltaTime: CFTimeInterval = 0.05

    /// Порог в радианах, ниже которого pitch считается доехавшим до цели и follow снимается.
    static let snapThreshold: Float = 0.0003

    /// Порог отсутствия прогресса: если фактический pitch не сдвинулся между кадрами (уперся
    /// в clamp/потолок), а до цели все еще далеко, follow надо остановить, а не крутить вечно.
    static let progressThreshold: Float = 0.00002

    static func clampedDeltaTime(_ deltaTime: CFTimeInterval) -> CFTimeInterval {
        guard deltaTime.isFinite else {
            return 0
        }

        return min(max(0, deltaTime), maximumDeltaTime)
    }

    /// Новый pitch на кадр: остаток гэпа до цели домножается на half-life factor.
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

    /// true, если фактический pitch застрял (уперся в clamp у потолка): прогресса между кадрами
    /// нет, но цель не достигнута. Нужно, чтобы follow не крутил display link бесконечно.
    static func isStalled(current: Float, previous: Float, target: Float) -> Bool {
        abs(current - previous) <= progressThreshold && abs(target - current) > snapThreshold
    }
}
