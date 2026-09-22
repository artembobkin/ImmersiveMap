// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Local scale of the render surface at the view centre relative to
/// normalized Mercator: the sphere compresses the world by
/// `cos(latitude)`, the plane does not, and through the globe-to-plane
/// transition the unroll's chart blend (`GlobeUnrollMath`) with the flat
/// target inflating from `cos` to 1 (`globeTransitionMapSize`) gives
/// `cos + g^2 (1 - cos)` for the geometry phase `g`, which reaches 1 at
/// `PresentationStateResolver.geometryCompletionPhase` of the transition.
/// The camera proximity, the pan compensation and the zoom anchor all
/// read this one curve, so they agree with the geometry on screen.
enum SurfaceScaleMath {
    /// - Parameter transition: globe-to-plane phase: 0 is globe, 1 is plane.
    static func surfaceScale(latitude: Double, transition: Float) -> Double {
        let geometryPhase = Double(PresentationStateResolver.geometryTransition(transition))
        let compression = max(cos(latitude), 1e-6)
        return compression + geometryPhase * geometryPhase * (1.0 - compression)
    }
}
