// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

enum PitchControlMath {
    static func clampedControlValue(_ value: Float, maximumPitch: Float) -> Float {
        min(max(0, value), maximumPitch)
    }

    static func actualPitch(forControlValue value: Float, maximumPitch: Float) -> Float {
        maximumPitch - clampedControlValue(value, maximumPitch: maximumPitch)
    }

    static func controlValue(forActualPitch pitch: Float, maximumPitch: Float) -> Float {
        clampedControlValue(maximumPitch - min(max(0, pitch), maximumPitch), maximumPitch: maximumPitch)
    }

    static func controlValueDelta(forVerticalTranslation translationY: CGFloat,
                                  interactionHeight: CGFloat,
                                  maximumPitch: Float) -> Float {
        guard interactionHeight > 0, maximumPitch > 0 else {
            return 0
        }

        return -Float(translationY / interactionHeight) * maximumPitch
    }
}
