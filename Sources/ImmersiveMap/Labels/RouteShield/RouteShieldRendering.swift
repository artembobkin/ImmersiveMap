// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The look of one run of route sign plates, as the tile bakes it: the
/// style's `RouteShieldAppearance` with its em fractions resolved to layout
/// points at the numbers' size. Every plate of a run shares it, so a run is
/// one draw with one uniform. A plate's own size travels in its vertices.
struct RouteShieldRunStyle: Hashable, Sendable {
    var shape: RouteShieldAppearance.Shape
    var fillColor: SIMD3<Float>
    var borderColor: SIMD3<Float>
    /// The band across the top, nil for a plate in one colour.
    var headerColor: SIMD3<Float>?
    /// The band's height as a fraction of the plate's.
    var headerFraction: Float
    var borderWidthPoints: Float
    var cornerRadiusPoints: Float
}

/// The fragment uniform of `routeShieldFragment` (RouteShield.metal). The
/// layout matches the shader's `RouteShieldStyle`.
struct RouteShieldStyleUniform: Equatable {
    var fillColor: SIMD4<Float>
    var borderColor: SIMD4<Float>
    var headerColor: SIMD4<Float>
    var borderWidthPoints: Float
    var cornerRadiusPoints: Float
    /// Zero for a plate with no band.
    var headerFraction: Float
    var shape: UInt32

    init(_ style: RouteShieldRunStyle) {
        fillColor = SIMD4<Float>(style.fillColor, 1)
        borderColor = SIMD4<Float>(style.borderColor, 1)
        headerColor = SIMD4<Float>(style.headerColor ?? style.fillColor, 1)
        borderWidthPoints = style.borderWidthPoints
        cornerRadiusPoints = style.cornerRadiusPoints
        headerFraction = style.headerColor == nil ? 0 : style.headerFraction
        shape = UInt32(style.shape.rawValue)
    }
}
