// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

enum ZoomControlMath {
    static func zoomDelta(forVerticalTranslation translationY: CGFloat,
                          velocityY: CGFloat,
                          interactionHeight: CGFloat,
                          zoomFactor: Double,
                          velocityFactor: Double,
                          velocityLimit: Double) -> Double {
        guard interactionHeight > 0,
              zoomFactor.isFinite,
              velocityFactor.isFinite,
              velocityLimit.isFinite else {
            return 0
        }

        let normalizedTranslation = -Double(translationY / interactionHeight)
        let baseDelta = normalizedTranslation * zoomFactor
        guard baseDelta.isFinite, baseDelta != 0 else {
            return 0
        }

        let normalizedVelocity = -Double(velocityY / interactionHeight)
        let alignedVelocityMagnitude: Double
        if normalizedVelocity.isFinite, baseDelta * normalizedVelocity > 0 {
            alignedVelocityMagnitude = min(abs(normalizedVelocity), max(0, velocityLimit))
        } else {
            alignedVelocityMagnitude = 0
        }

        let boost = 1.0 + alignedVelocityMagnitude * max(0, velocityFactor)
        return baseDelta * boost
    }
}
