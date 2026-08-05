// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Timing of a traversal of an ``ImmersiveMapGeoPath``: a scene model flying
/// along it, or the camera following it. Shared so a model and the camera
/// started together stay in step.
public enum ImmersiveMapPathAnimationCurve: Sendable {
    /// Constant ground speed over the whole path.
    case linear
    /// Cubic ease-out: leaves at full speed and settles onto the destination.
    case easeOut
}

extension ImmersiveMapPathAnimationCurve {
    /// Fraction of the path travelled after `elapsed` seconds of a `duration`
    /// traversal, clamped to `0...1`. The single definition, so a model and a
    /// camera started together sit at the same point of the path.
    func fraction(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let raw = min(max(elapsed / duration, 0), 1)
        switch self {
        case .linear:
            return raw
        case .easeOut:
            let inverse = 1 - raw
            return 1 - inverse * inverse * inverse
        }
    }
}
