// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

enum PinchZoomMath {
    static func zoomDelta(scale: Double,
                          velocity: Double,
                          pinchZoomFactor: Double,
                          pinchZoomVelocityFactor: Double,
                          pinchZoomVelocityLimit: Double) -> Double {
        let scaleDelta = scale - 1.0
        guard scaleDelta.isFinite,
              velocity.isFinite,
              pinchZoomFactor.isFinite,
              pinchZoomVelocityFactor.isFinite,
              pinchZoomVelocityLimit.isFinite else {
            return 0
        }

        let alignedVelocityMagnitude: Double
        if scaleDelta == 0 || scaleDelta * velocity <= 0 {
            alignedVelocityMagnitude = 0
        } else {
            alignedVelocityMagnitude = min(abs(velocity), max(0, pinchZoomVelocityLimit))
        }

        let boost = 1.0 + alignedVelocityMagnitude * max(0, pinchZoomVelocityFactor)
        return scaleDelta * pinchZoomFactor * boost
    }
}
