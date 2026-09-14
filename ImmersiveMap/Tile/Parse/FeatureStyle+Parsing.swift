// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// What the parser bakes of a style into a tile's style table: the colours
/// of one stroke or fill and its line parameters, keyed by the style's key.
/// A fill is baked as a stroke of the fill's colours on the standard fill
/// ribbon width; the far colours and the outline flag are a fill's alone.
struct BakedStyle {
    let pass: LinePass
    let farColor: SIMD4<Float>?
    let farStreetColor: SIMD4<Float>?
    let outlineAntialiasing: Bool

    /// The ribbon width every fill is baked with: the edge threshold it
    /// yields is what the fill shaders have always read.
    static let fillRibbonWidth: Double = 100

    init(pass: LinePass) {
        self.pass = pass
        self.farColor = nil
        self.farStreetColor = nil
        self.outlineAntialiasing = false
    }

    init(fill: FillStyle) {
        self.pass = LinePass(key: fill.key,
                             color: fill.color,
                             streetColor: fill.streetColor,
                             lowZoomFadeMask: fill.lowZoomFadeMask,
                             lineGeometry: LineGeometryStyle(lineWidth: Self.fillRibbonWidth))
        self.farColor = fill.farColor
        self.farStreetColor = fill.farStreetColor
        self.outlineAntialiasing = fill.outlineAntialiasing
    }

    init(extrusion: ExtrusionStyle) {
        self.pass = LinePass(key: extrusion.key,
                             color: extrusion.color,
                             streetColor: extrusion.streetColor,
                             lineGeometry: LineGeometryStyle(lineWidth: Self.fillRibbonWidth))
        self.farColor = nil
        self.farStreetColor = nil
        self.outlineAntialiasing = false
    }

    var color: SIMD4<Float> { pass.color }
    var streetColor: SIMD4<Float>? { pass.streetColor }
    var lowZoomFadeMask: Float { pass.lowZoomFadeMask }
}

/// What the parser derives from a style before it reads a feature: the
/// style with the road paint taken off when the streetscape is off.
/// `FeatureStyle` itself is the style's pure answer and knows nothing of
/// the parse.
extension FeatureStyle {
    /// The style with the road paint taken off it, which is what the parser
    /// bakes when the streetscape is off: a road is its casing and fill by
    /// class, a parking lot its asphalt and kerb, and nothing is painted on
    /// either. The paint strokes go (the lane lines and centre divider
    /// synthesized from the lane count, the parking-bay comb), a shipped
    /// marking or a paint-only decoration is hidden outright rather than
    /// left to fall back on a fill ribbon of its own colour, and a surface
    /// no longer cuts the paint it no longer has. The one decoration that
    /// stays is the zebra crossing read off the road's own `crossing`
    /// attribute: a crossing is part of a street map, not of the measured
    /// streetscape. Every other style comes back as it is. `isShippedPaint`
    /// is the reading's word on the feature (`ImmersiveMapRoadFacts.isShippedPaint`).
    func strippingRoadPaint(isShippedPaint: Bool = false) -> FeatureStyle {
        guard case .road(var road) = self else {
            return self
        }
        if road.decoration == .zebraCrossing, isShippedPaint == false {
            return self
        }
        let hasRoadPaint = isShippedPaint
            || road.decoration != .none
            || road.surfaceCutsPaint
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
        road.surfaceCutsPaint = false
        return .road(road)
    }
}
