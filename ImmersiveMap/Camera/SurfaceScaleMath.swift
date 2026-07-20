// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Локальный масштаб поверхности рендера относительно нормализованного меркатора
/// на заданной широте: сфера сжимает мир на `cos(latitude)`, плоскость не сжимает;
/// между ними линейная интерполяция по фазе перехода глобус→плоскость.
enum SurfaceScaleMath {
    /// - Parameter transition: фаза глобус→плоскость: 0 — глобус, 1 — плоскость.
    static func surfaceScale(latitude: Double, transition: Float) -> Double {
        let flatness = Double(min(max(transition, 0.0), 1.0))
        return flatness + (1.0 - flatness) * max(cos(latitude), 1e-6)
    }
}
