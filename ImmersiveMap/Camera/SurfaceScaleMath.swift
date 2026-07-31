// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Local scale of the render surface relative to normalized Mercator
/// at a given latitude: the sphere compresses the world by `cos(latitude)`, the plane does not;
/// between them, linear interpolation over the globe→plane transition phase.
enum SurfaceScaleMath {
    /// - Parameter transition: globe→plane phase: 0 — globe, 1 — plane.
    static func surfaceScale(latitude: Double, transition: Float) -> Double {
        let flatness = Double(min(max(transition, 0.0), 1.0))
        return flatness + (1.0 - flatness) * max(cos(latitude), 1e-6)
    }
}
