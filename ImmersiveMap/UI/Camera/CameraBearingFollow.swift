// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Time-based follower for camera bearing: the control sets the target angle instantly, while the
/// actual bearing converges to it exponentially every frame (half-life), along the shortest angular
/// path when rotation is unbounded and along the in-window path under a bearing cap.
/// Removes rotation jerkiness caused by the uneven event rate of the slider/gesture.
final class CameraBearingFollow {
    struct Configuration {
        fileprivate let isEnabled: Bool
        fileprivate let halfLife: Double

        init(isEnabled: Bool, halfLife: Double) {
            self.isEnabled = isEnabled
            self.halfLife = max(0.001, halfLife.isFinite ? halfLife : 0.06)
        }
    }

    struct Step {
        let bearing: Float
        let isActive: Bool
    }

    private var configuration: Configuration
    private var isActive = false
    private var target: Float = 0
    private var lastTickTime: CFTimeInterval?
    private var previousBearing: Float?

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

    /// Sets a new target. Returns false if follow is disabled by settings, in which case the caller
    /// must apply the bearing instantly (legacy behavior without smoothing).
    @discardableResult
    func retarget(_ bearing: Float, currentTime: CFTimeInterval) -> Bool {
        guard configuration.isEnabled else {
            cancel()
            return false
        }

        target = bearing
        if isActive == false {
            lastTickTime = currentTime
            previousBearing = nil
            isActive = true
        }

        return true
    }

    func advance(currentBearing: Float,
                 currentTime: CFTimeInterval,
                 maximumAbsoluteBearing: Float = .pi) -> Step {
        guard isActive else {
            return Step(bearing: currentBearing, isActive: false)
        }

        guard let lastTickTime else {
            self.lastTickTime = currentTime
            self.previousBearing = currentBearing
            return Step(bearing: currentBearing, isActive: true)
        }

        let deltaTime = CameraBearingFollowMath.clampedDeltaTime(currentTime - lastTickTime)
        self.lastTickTime = currentTime
        guard deltaTime > 0 else {
            return Step(bearing: currentBearing, isActive: true)
        }

        if let previousBearing,
           CameraBearingFollowMath.isStalled(current: currentBearing, previous: previousBearing, target: target) {
            cancel()
            return Step(bearing: currentBearing, isActive: false)
        }

        if CameraBearingFollowMath.shouldSnap(current: currentBearing, target: target) {
            cancel()
            return Step(bearing: target, isActive: false)
        }

        let nextBearing = CameraBearingFollowMath.steppedBearing(current: currentBearing,
                                                                target: target,
                                                                deltaTime: deltaTime,
                                                                halfLife: configuration.halfLife,
                                                                maximumAbsoluteBearing: maximumAbsoluteBearing)
        self.previousBearing = currentBearing
        return Step(bearing: nextBearing, isActive: true)
    }

    func cancel() {
        isActive = false
        lastTickTime = nil
        previousBearing = nil
    }
}
