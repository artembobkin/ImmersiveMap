// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  GlobeCameraPanInertiaMath.swift
//  ImmersiveMap
//

import CoreGraphics
import Foundation

enum GlobeCameraPanInertiaMath {
    static let maximumDeltaTime: CFTimeInterval = 0.05

    static func speed(of velocity: CGPoint) -> Double {
        hypot(Double(velocity.x), Double(velocity.y))
    }

    static func shouldStart(with velocity: CGPoint,
                            activationVelocity: Double) -> Bool {
        speed(of: velocity) >= max(0, activationVelocity)
    }

    static func shouldStop(with velocity: CGPoint,
                           stopVelocity: Double) -> Bool {
        speed(of: velocity) <= max(0, stopVelocity)
    }

    static func clampedInitialVelocity(_ velocity: CGPoint,
                                       maximumVelocity: Double) -> CGPoint {
        let limit = max(0, maximumVelocity)
        let speed = speed(of: velocity)
        guard speed.isFinite, speed > 0, speed > limit, limit > 0 else {
            return velocity
        }

        let scale = limit / speed
        return CGPoint(x: velocity.x * scale, y: velocity.y * scale)
    }

    static func clampedDeltaTime(_ deltaTime: CFTimeInterval) -> CFTimeInterval {
        guard deltaTime.isFinite else {
            return 0
        }

        return min(max(0, deltaTime), maximumDeltaTime)
    }

    static func decayedVelocity(_ velocity: CGPoint,
                                deltaTime: CFTimeInterval,
                                halfLife: Double) -> CGPoint {
        let sanitizedHalfLife = max(0.001, halfLife.isFinite ? halfLife : 0.001)
        let factor = exp(-log(2.0) * deltaTime / sanitizedHalfLife)
        return CGPoint(x: velocity.x * factor, y: velocity.y * factor)
    }
}
