// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeCameraPanInertia.swift
//  ImmersiveMap
//

import CoreGraphics
import Foundation

/// Симулирует post-pan inertia для движения globe camera.
/// Хранит decay state и возвращает translations для каждого frame, пока движение не остановится.
final class GlobeCameraPanInertia {
    struct Step {
        let translation: CGPoint
        let isActive: Bool
    }

    struct Configuration {
        fileprivate let isEnabled: Bool
        fileprivate let halfLife: Double
        fileprivate let activationVelocity: Double
        fileprivate let stopVelocity: Double
        fileprivate let maximumInitialVelocity: Double

        init(isEnabled: Bool,
             halfLife: Double,
             activationVelocity: Double,
             stopVelocity: Double,
             maximumInitialVelocity: Double) {
            self.isEnabled = isEnabled
            self.halfLife = max(0.001, halfLife.isFinite ? halfLife : 0.28)
            self.activationVelocity = max(0, activationVelocity.isFinite ? activationVelocity : 0)
            self.stopVelocity = max(0, stopVelocity.isFinite ? stopVelocity : 0)
            self.maximumInitialVelocity = max(0, maximumInitialVelocity.isFinite ? maximumInitialVelocity : 0)
        }
    }

    private var configuration: Configuration
    private var isActive: Bool = false
    private var velocity: CGPoint = .zero
    private var lastTickTime: CFTimeInterval?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    @discardableResult
    func updateConfiguration(_ configuration: Configuration) -> Bool {
        self.configuration = configuration
        if configuration.isEnabled == false {
            cancel()
        }

        return isActive
    }

    @discardableResult
    func start(initialVelocity: CGPoint,
               currentTime: CFTimeInterval) -> Bool {
        guard configuration.isEnabled,
              GlobeCameraPanInertiaMath.shouldStart(with: initialVelocity,
                                                    activationVelocity: configuration.activationVelocity) else {
            cancel()
            return false
        }

        velocity = GlobeCameraPanInertiaMath.clampedInitialVelocity(initialVelocity,
                                                                    maximumVelocity: configuration.maximumInitialVelocity)
        lastTickTime = currentTime
        isActive = true
        return true
    }

    func advance(currentTime: CFTimeInterval) -> Step {
        guard isActive else {
            return Step(translation: .zero,
                        isActive: false)
        }

        guard let lastTickTime else {
            self.lastTickTime = currentTime
            return Step(translation: .zero,
                        isActive: isActive)
        }

        let deltaTime = GlobeCameraPanInertiaMath.clampedDeltaTime(currentTime - lastTickTime)
        self.lastTickTime = currentTime
        guard deltaTime > 0 else {
            return Step(translation: .zero,
                        isActive: isActive)
        }

        let translation = CGPoint(x: velocity.x * deltaTime,
                                  y: velocity.y * deltaTime)
        velocity = GlobeCameraPanInertiaMath.decayedVelocity(velocity,
                                                             deltaTime: deltaTime,
                                                             halfLife: configuration.halfLife)
        if GlobeCameraPanInertiaMath.shouldStop(with: velocity,
                                                stopVelocity: configuration.stopVelocity) {
            cancel()
        }

        return Step(translation: translation,
                    isActive: isActive)
    }

    func cancel() {
        isActive = false
        velocity = .zero
        lastTickTime = nil
    }
}
