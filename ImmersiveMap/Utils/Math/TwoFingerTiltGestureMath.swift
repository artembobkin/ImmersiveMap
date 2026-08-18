// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Decides when a two-finger drag on the map is a tilt and how far it tilts.
/// A tilt is a drag with the fingers roughly side by side moving mostly
/// vertically; a pinch or a rotation moves the fingers against each other, so
/// their average translation stays short and never crosses the activation
/// distance. The gesture layer feeds these decisions with the recognizer's
/// touch locations and accumulated translation and applies the resulting
/// pitch delta through the camera runtime.
enum TwoFingerTiltGestureMath {
    /// What an accumulated two-finger translation has revealed so far.
    enum Intent: Equatable {
        /// Too little movement to tell a tilt from a pinch or rotation.
        case undecided
        /// Mostly vertical movement: the drag is a tilt.
        case tilt
        /// Mostly horizontal movement: leave the drag to the other gestures.
        case other
    }

    /// How far the fingers travel together before the drag commits to being
    /// a tilt or not, in points.
    static let activationDistance: CGFloat = 8

    /// Two fingers roughly side by side may tilt; fingers stacked closer to
    /// vertically than horizontally are a pinch or rotation posture, and a
    /// vertical drag from it would zoom or spin in every other map, so it
    /// never tilts here either.
    static func touchLayoutAllowsTilt(_ first: CGPoint, _ second: CGPoint) -> Bool {
        abs(second.y - first.y) <= abs(second.x - first.x)
    }

    /// Classifies the translation accumulated since the gesture began.
    /// The answer is only meaningful until the first non-`undecided` result;
    /// after that the caller sticks with its decision for the rest of the
    /// gesture rather than re-litigating it on every finger wobble.
    static func intent(ofTranslation translation: CGPoint,
                       activationDistance: CGFloat = activationDistance) -> Intent {
        guard translation.x.magnitude + translation.y.magnitude >= activationDistance else {
            return .undecided
        }
        return translation.y.magnitude > translation.x.magnitude ? .tilt : .other
    }

    /// Dragging across the full view height sweeps the full pitch ceiling
    /// `sensitivity` times over, on iOS and macOS alike: down tilts further,
    /// up levels off. `CameraSettings.tiltGestureSensitivity` feeds the
    /// multiplier, and its sign picks the direction, so a negative value
    /// inverts the drag (up tilts further).
    static func pitchDelta(forVerticalTranslation translationY: CGFloat,
                           viewHeight: CGFloat,
                           maximumPitch: Float,
                           sensitivity: Float) -> Float {
        guard viewHeight > 0 else {
            return 0
        }
        return Float(translationY / viewHeight) * max(maximumPitch, 0) * sensitivity
    }
}
