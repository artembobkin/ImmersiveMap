// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// The one-thumb tilt zone works in an inverted control value: 0 is the full
/// tilt (the pitch ceiling), and the value grows as the camera levels off, so
/// the reachable span is the distance from the ceiling down to the floor.
enum PitchControlMath {
    static func reachablePitchSpan(minimumPitch: Float, maximumPitch: Float) -> Float {
        let ceiling = max(maximumPitch, 0)
        let floor = min(max(minimumPitch, 0), ceiling)
        return ceiling - floor
    }

    static func clampedControlValue(_ value: Float, minimumPitch: Float, maximumPitch: Float) -> Float {
        min(max(0, value), reachablePitchSpan(minimumPitch: minimumPitch, maximumPitch: maximumPitch))
    }

    static func actualPitch(forControlValue value: Float, minimumPitch: Float, maximumPitch: Float) -> Float {
        max(maximumPitch, 0) - clampedControlValue(value, minimumPitch: minimumPitch, maximumPitch: maximumPitch)
    }

    static func controlValue(forActualPitch pitch: Float, minimumPitch: Float, maximumPitch: Float) -> Float {
        clampedControlValue(max(maximumPitch, 0) - pitch, minimumPitch: minimumPitch, maximumPitch: maximumPitch)
    }

    static func controlValueDelta(forVerticalTranslation translationY: CGFloat,
                                  interactionHeight: CGFloat,
                                  minimumPitch: Float,
                                  maximumPitch: Float) -> Float {
        let span = reachablePitchSpan(minimumPitch: minimumPitch, maximumPitch: maximumPitch)
        guard interactionHeight > 0, span > 0 else {
            return 0
        }

        return -Float(translationY / interactionHeight) * span
    }
}
