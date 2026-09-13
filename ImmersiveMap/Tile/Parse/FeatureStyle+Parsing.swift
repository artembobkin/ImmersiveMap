// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What the parser derives from a style before it reads a feature: the
/// passes a line draws, and the style with the road paint taken off when the
/// streetscape is off. `FeatureStyle` itself is the style's pure answer and
/// knows nothing of the parse.
extension FeatureStyle {
    /// The style with the road paint taken off it, which is what the parser
    /// bakes when the streetscape is off: a road is its casing and fill by
    /// class, a parking lot its asphalt and kerb, and nothing is painted on
    /// either. The detail passes go (the lane lines and centre divider
    /// synthesized from the lane count, the parking-bay comb), a shipped
    /// marking or a paint-only decoration is hidden outright rather than
    /// left to fall back on a fill ribbon of its own colour, and a surface
    /// no longer cuts the paint it no longer has. The one decoration that
    /// stays is the zebra crossing read off the road's own `crossing`
    /// attribute: a crossing is part of a street map, not of the measured
    /// streetscape. Every other style comes back as it is.
    func strippingRoadPaint() -> FeatureStyle {
        if roadDecorationKind == .zebraCrossing, isShippedRoadPaint == false {
            return self
        }
        let hasRoadPaint = isShippedRoadPaint
            || roadDecorationKind != .none
            || surfaceAreaCutsPaint
            || lineRenderPasses.contains { $0.roadPassRole == .detail }
        guard hasRoadPaint else {
            return self
        }
        let keptPasses = lineRenderPasses.filter { $0.roadPassRole != .detail }
        let paintOnly = isShippedRoadPaint
            || (lineRenderPasses.isEmpty == false && keptPasses.isEmpty)
        if paintOnly {
            return FeatureStyle(key: 0,
                                color: SIMD4<Float>(repeating: 0),
                                parseGeometryStyleData: parseGeometryStyleData)
        }
        return FeatureStyle(key: key,
                            color: color,
                            streetColor: streetColor,
                            farColor: farColor,
                            farStreetColor: farStreetColor,
                            lowZoomFadeMask: lowZoomFadeMask,
                            lineWidthPoints: lineWidthPoints,
                            dashLengthPoints: dashLengthPoints,
                            dashGapPoints: dashGapPoints,
                            dashInTileUnits: dashInTileUnits,
                            minimumWidthPoints: minimumWidthPoints,
                            maximumWidthPoints: maximumWidthPoints,
                            parseGeometryStyleData: parseGeometryStyleData,
                            includeRoadLabelPath: includeRoadLabelPath,
                            linePlacement: linePlacement,
                            lineRenderPasses: keptPasses,
                            roadClassPriority: roadClassPriority,
                            usesExtrusion: usesExtrusion,
                            extrusionHeightScale: extrusionHeightScale,
                            extrusionAnchorZoom: extrusionAnchorZoom,
                            extrusionFallbackHeight: extrusionFallbackHeight,
                            labelTextStyle: labelTextStyle,
                            roadLabelTextStyle: roadLabelTextStyle,
                            roadDecorationKind: .none,
                            isRoadSurfaceArea: isRoadSurfaceArea,
                            surfaceAreaCutsPaint: false,
                            isShippedRoadPaint: false,
                            labelMinCameraZoom: labelMinCameraZoom,
                            suppressPolygonFill: suppressPolygonFill,
                            fillOutlineAntialiasing: fillOutlineAntialiasing)
    }

    var resolvedLineRenderPasses: [LineRenderPass] {
        if lineRenderPasses.isEmpty == false {
            return lineRenderPasses
        }
        return [
            LineRenderPass(key: key,
                           color: color,
                           streetColor: streetColor,
                           lowZoomFadeMask: lowZoomFadeMask,
                           lineWidthPoints: lineWidthPoints,
                           dashLengthPoints: dashLengthPoints,
                           dashGapPoints: dashGapPoints,
                           dashInTileUnits: dashInTileUnits,
                           minimumWidthPoints: minimumWidthPoints,
                           maximumWidthPoints: maximumWidthPoints,
                           parseGeometryStyleData: parseGeometryStyleData,
                           includeRoadLabelPath: includeRoadLabelPath,
                           placement: linePlacement,
                           roadPassRole: .fill)
        ]
    }
}
