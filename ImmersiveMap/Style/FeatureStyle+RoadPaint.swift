// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

public extension FeatureStyle {
    /// The style with the road paint taken off it, for a map that draws no
    /// streetscape (`ImmersiveMapFeatureStyleContext.streetscapeEnabled`
    /// false): a road is its casing and fill by class, a parking lot its
    /// asphalt and kerb, and nothing is painted on either. The paint
    /// strokes go (the lane lines and centre divider synthesized from the
    /// lane count, the parking-bay comb), a shipped marking or a paint-only
    /// decoration is hidden outright rather than left to fall back on a
    /// fill ribbon of its own colour, and a surface no longer cuts the
    /// paint it no longer has. The one decoration that stays is the zebra
    /// crossing read off the road's own `crossing` attribute: a crossing
    /// is part of a street map, not of the measured streetscape. Every
    /// other style comes back as it is.
    ///
    /// A style calls this itself where it wants the bare street map; the
    /// engine strips nothing. `isShippedPaint` is the reading's word on the
    /// feature (`ImmersiveMapRoadFacts.isShippedPaint`).
    func strippingRoadPaint(isShippedPaint: Bool = false) -> FeatureStyle {
        guard case .road(var road) = self else {
            return self
        }
        if road.decoration.isZebraCrossing, isShippedPaint == false {
            return self
        }
        let hasRoadPaint = isShippedPaint
            || road.decoration.isNone == false
            || road.surfacePaint != .keeps
            || road.paint.isEmpty == false
        guard hasRoadPaint else {
            return self
        }
        let paintOnly = isShippedPaint
            || (road.shadow == nil && road.casing == nil && road.fill == nil && road.overlay == nil)
        if paintOnly {
            return .hidden
        }
        road.paint = []
        road.decoration = .none
        road.surfacePaint = .keeps
        return .road(road)
    }
}
