// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Timing of a scene model flying along an ``ImmersiveMapGeoPath``.
public enum ImmersiveMapPathAnimationCurve: Sendable {
    /// Constant ground speed over the whole path.
    case linear
    /// Cubic ease-out: leaves at full speed and settles onto the destination.
    case easeOut
}
