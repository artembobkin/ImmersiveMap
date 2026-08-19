// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The point-locked line: the one way the engine draws symbolic lines, first
/// proven on country borders and then adopted by the overview road skeleton.
///
/// A symbolic line (a border, a motorway over a country view) is a drawn
/// stroke, not a surface: its width is a design decision in on-screen points,
/// not a property of the world. The factory packages the five decisions the
/// principle consists of, so every adopter gets all of them and none by
/// accident:
///
/// 1. **Point-locked width**: `lineWidthPoints` resolves the visible edge in
///    screen space at render time, so the stroke holds its size through every
///    zoom instead of pumping with the tile scale.
/// 2. **Opaque from the first visible frame**: `lowZoomFadeMask` 1 rides the
///    overview fade band, fully opaque past z1, never a band that would keep
///    the line translucent at the zooms it is drawn for. A translucent stroke
///    composites unevenly wherever segments overlap.
/// 3. **Butt ends and plain joins**: round caps scale with the tessellated
///    ribbon, and their translucent overlaps darken every joint.
/// 4. **Point-based dashes**: the pattern is stated in layout points and cut
///    per fragment from arc length, so it reads as dashes at every zoom.
/// 5. **A ribbon that can host the width**: the shader clamps the point edge
///    to the tessellated ribbon (`tileLineCoverage` in Tile.metal), so the
///    geometry is provisioned as a ceiling well above the request. The ribbon
///    is never the visible width; over-provisioning costs only a wider quad.
extension FeatureStyle {
    /// Tile units of tessellated ribbon per requested point of visible width.
    /// Sized so the ceiling stays above the request on large, dense displays;
    /// see decision 5 above.
    static let pointLockedRibbonUnitsPerPoint: Double = 32

    static func pointLockedLine(key: UInt8,
                                color: SIMD4<Float>,
                                streetColor: SIMD4<Float>? = nil,
                                widthPoints: Float,
                                dashLengthPoints: Float = 0,
                                dashGapPoints: Float = 0,
                                suppressPolygonFill: Bool = false,
                                roadClassPriority: Int = 0) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
            streetColor: streetColor,
            lowZoomFadeMask: 1.0,
            lineWidthPoints: widthPoints,
            dashLengthPoints: dashLengthPoints,
            dashGapPoints: dashGapPoints,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(
                lineWidth: Double(widthPoints) * Self.pointLockedRibbonUnitsPerPoint
            ),
            roadClassPriority: roadClassPriority,
            suppressPolygonFill: suppressPolygonFill
        )
    }
}
