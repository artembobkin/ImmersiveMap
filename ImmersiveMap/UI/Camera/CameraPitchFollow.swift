// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Time-based follower для camera pitch: жест задает целевой угол мгновенно, а фактический pitch
/// каждый кадр экспоненциально подводится к цели по half-life. Убирает дёрганье наклона от
/// неравномерной частоты touch-событий: шаг на кадр нормируется по времени, а не по числу событий.
final class CameraPitchFollow {
    struct Configuration {
        fileprivate let isEnabled: Bool
        fileprivate let halfLife: Double

        init(isEnabled: Bool, halfLife: Double) {
            self.isEnabled = isEnabled
            self.halfLife = max(0.001, halfLife.isFinite ? halfLife : 0.06)
        }
    }

    struct Step {
        let pitch: Float
        let isActive: Bool
    }

    private var configuration: Configuration
    private var isActive = false
    private var target: Float = 0
    private var lastTickTime: CFTimeInterval?
    private var previousPitch: Float?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    var active: Bool {
        isActive
    }

    @discardableResult
    func updateConfiguration(_ configuration: Configuration) -> Bool {
        self.configuration = configuration
        if configuration.isEnabled == false {
            cancel()
        }

        return isActive
    }

    /// Задает новую цель. Возвращает false, если follow выключен настройкой — тогда вызывающий
    /// должен применить pitch мгновенно (legacy-поведение без сглаживания).
    @discardableResult
    func retarget(_ pitch: Float, currentTime: CFTimeInterval) -> Bool {
        guard configuration.isEnabled else {
            cancel()
            return false
        }

        target = pitch
        if isActive == false {
            lastTickTime = currentTime
            previousPitch = nil
            isActive = true
        }

        return true
    }

    func advance(currentPitch: Float, currentTime: CFTimeInterval) -> Step {
        guard isActive else {
            return Step(pitch: currentPitch, isActive: false)
        }

        guard let lastTickTime else {
            self.lastTickTime = currentTime
            self.previousPitch = currentPitch
            return Step(pitch: currentPitch, isActive: true)
        }

        let deltaTime = CameraPitchFollowMath.clampedDeltaTime(currentTime - lastTickTime)
        self.lastTickTime = currentTime
        guard deltaTime > 0 else {
            return Step(pitch: currentPitch, isActive: true)
        }

        if let previousPitch,
           CameraPitchFollowMath.isStalled(current: currentPitch, previous: previousPitch, target: target) {
            cancel()
            return Step(pitch: currentPitch, isActive: false)
        }

        if CameraPitchFollowMath.shouldSnap(current: currentPitch, target: target) {
            cancel()
            return Step(pitch: target, isActive: false)
        }

        let nextPitch = CameraPitchFollowMath.steppedPitch(current: currentPitch,
                                                           target: target,
                                                           deltaTime: deltaTime,
                                                           halfLife: configuration.halfLife)
        self.previousPitch = currentPitch
        return Step(pitch: nextPitch, isActive: true)
    }

    func cancel() {
        isActive = false
        lastTickTime = nil
        previousPitch = nil
    }
}
