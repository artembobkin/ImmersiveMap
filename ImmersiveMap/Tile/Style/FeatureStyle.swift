// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

public enum LabelFontWeight: UInt8, Sendable {
    case bold = 0
    case thin = 1
}

enum LinePlacement {
    case ground
    case bridgeOverlay
}

enum RoadPassRole: Int, CaseIterable {
    case shadow
    case casing
    case fill
    case detail
    case overlay
}

struct LabelTextStyle {
    let key: Int
    let fillColor: SIMD3<Float>
    let strokeColor: SIMD3<Float>
    /// Halo width as a fraction of the em, so that it tracks the text size
    /// instead of drifting: an absolute width makes the smallest labels carry
    /// the widest halo relative to their strokes.
    let haloEm: Float
    /// Em size in layout points. Converted to device pixels once, at the render
    /// boundary (see `ScreenScale`).
    let sizePoints: Float
    let weight: LabelFontWeight

    /// Halo width in device pixels for this style at a given screen scale.
    func haloWidthPixels(screenScale: ScreenScale) -> Float {
        screenScale.pixels(haloEm * sizePoints)
    }
}

struct LineRenderPass {
    let key: UInt8
    let color: SIMD4<Float>
    let lowZoomFadeMask: Float
    /// Point-locked visible line width (full width, layout points). Zero keeps
    /// the world-locked behavior: the visible edge is the tessellated width.
    /// Non-zero resolves the edge in screen space at render time, so the width
    /// holds steady through fractional zoom instead of pumping with the tile's
    /// on-screen scale; the tessellated width then only bounds how wide the
    /// line can get. See `tileLineCoverage` in Tile.metal.
    let lineWidthPoints: Float
    /// Point-locked dash pattern (layout points), cut per fragment from the
    /// vertices' arc-length parameter, so dashes hold their on-screen size at
    /// every zoom. Zero dash length draws solid. A pass with a point dash is
    /// tessellated as a continuous line: the unit-based dash fields of
    /// `parseGeometryStyleData` must stay zero for it.
    let dashLengthPoints: Float
    let dashGapPoints: Float
    /// True when `dashLengthPoints`/`dashGapPoints` are tile units rather
    /// than points: a world-locked pattern, paint on the ground whose period
    /// is a length and must not re-flow with the camera or the serving tile
    /// level. See `TileLineStyle.dashInTileUnits`.
    let dashInTileUnits: Bool
    /// Floor for a world-locked width; see `TileLineStyle.minimumWidthPoints`.
    let minimumWidthPoints: Float
    /// Symbol ceiling for a world-locked width; see
    /// `TileLineStyle.maximumWidthPoints`.
    let maximumWidthPoints: Float
    /// Street-palette counterpart of `color` for passes whose color changes
    /// with the overview-to-street handover (the motorway accent); nil bakes
    /// `color` twice.
    let streetColor: SIMD4<Float>?
    let parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData
    let includeRoadLabelPath: Bool
    let placement: LinePlacement
    let roadPassRole: RoadPassRole

    init(key: UInt8,
         color: SIMD4<Float>,
         streetColor: SIMD4<Float>? = nil,
         lowZoomFadeMask: Float = 0.0,
         lineWidthPoints: Float = 0.0,
         dashLengthPoints: Float = 0.0,
         dashGapPoints: Float = 0.0,
         dashInTileUnits: Bool = false,
         minimumWidthPoints: Float = 0.0,
         maximumWidthPoints: Float = 0.0,
         parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData,
         includeRoadLabelPath: Bool,
         placement: LinePlacement = .ground,
         roadPassRole: RoadPassRole = .fill) {
        self.key = key
        self.color = color
        self.streetColor = streetColor
        self.lowZoomFadeMask = lowZoomFadeMask
        self.lineWidthPoints = lineWidthPoints
        self.dashLengthPoints = dashLengthPoints
        self.dashGapPoints = dashGapPoints
        self.dashInTileUnits = dashInTileUnits
        self.minimumWidthPoints = minimumWidthPoints
        self.maximumWidthPoints = maximumWidthPoints
        self.parseGeometryStyleData = parseGeometryStyleData
        self.includeRoadLabelPath = includeRoadLabelPath
        self.placement = placement
        self.roadPassRole = roadPassRole
    }
}

struct FeatureStyle {
    let key: UInt8
    let color: SIMD4<Float>
    /// Street-palette counterpart of `color` for ground styles that change
    /// with the overview-to-street handover; nil bakes `color` twice. See
    /// `TilePolygonStyle.streetColor`.
    let streetColor: SIMD4<Float>?
    /// The footprint fade target of a ground fill, the same globe/street
    /// pair, with the fade strength in the alpha; nil never fades. See
    /// `TilePolygonStyle.farColor`.
    let farColor: SIMD4<Float>?
    let farStreetColor: SIMD4<Float>?
    let lowZoomFadeMask: Float
    /// See `LineRenderPass.lineWidthPoints`; zero for world-locked lines and
    /// for all polygon geometry.
    let lineWidthPoints: Float
    /// See `LineRenderPass.dashLengthPoints`.
    let dashLengthPoints: Float
    let dashGapPoints: Float
    /// See `LineRenderPass.dashInTileUnits`.
    let dashInTileUnits: Bool
    /// See `TileLineStyle.minimumWidthPoints`.
    let minimumWidthPoints: Float
    /// See `TileLineStyle.maximumWidthPoints`.
    let maximumWidthPoints: Float
    let parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData
    let includeRoadLabelPath: Bool
    let linePlacement: LinePlacement
    let lineRenderPasses: [LineRenderPass]
    let roadClassPriority: Int
    let usesExtrusion: Bool
    let extrusionHeightScale: Float
    let extrusionAnchorZoom: Int
    let extrusionFallbackHeight: Float
    let labelTextStyle: LabelTextStyle?
    let roadLabelTextStyle: LabelTextStyle?
    let roadDecorationKind: TileMvtParser.RoadDecorationKind
    /// A polygon that is a carriageway surface (a junction area the tiles
    /// ship for a junction OSM maps as `area:highway`): it draws in the
    /// automobile road phases, its fill as the carriageway and its outline as
    /// the kerb, ordered among the roads so the surface covers the kerbs of
    /// every ribbon that enters it. False for every ground polygon.
    let isRoadSurfaceArea: Bool
    /// Whether this surface also cuts the PAINT of the roads inside it, on
    /// top of cutting their ribbons. True for a junction reconstructed from
    /// the road graph: there is no lane paint inside a crossing. False for a
    /// hand-mapped `area:highway`, which typically covers a whole street's
    /// carriageway: the street keeps its paint, drawn over the surface.
    let surfaceAreaCutsPaint: Bool
    /// Paint the source measured on the ground and shipped as its own line
    /// (`marking=...`): a lane line, a stop line, a crossing. It already ends
    /// exactly where it ends on the ground, so the engine's road machinery
    /// must not touch it: no clipping against carriageway surfaces, no
    /// junction making, no stitching, no junction inset (its passes carry
    /// `endInset` zero). False for every line the engine draws from a road's
    /// own geometry.
    let isShippedRoadPaint: Bool
    /// Minimum CAMERA zoom for this feature's point label (0 = always visible).
    /// Travels with the label to runtime, where it is compared against the current camera zoom.
    let labelMinCameraZoom: Float
    /// A line style (e.g. a border) must not fill areal geometry: some layer
    /// features arrive as polygons (Native American reservations in `boundary`),
    /// and filling them with the line color is wrong. The parser skips the
    /// polygon geometry of such features, keeping only the lines.
    let suppressPolygonFill: Bool
    /// A plain fill whose ring edges are antialiased by the fill-outline
    /// pass: the parser keeps the fill's ring edges as a line list and the
    /// flat drawer rasterizes them as one-pixel lines in the fill's colour,
    /// with alpha by distance to the edge, over the fill's own staircase
    /// (`ParsedPolygon.outlineIndices`). Fills only; a line style or an
    /// extruded polygon leaves it false.
    let fillOutlineAntialiasing: Bool

    init(
        key: UInt8,
        color: SIMD4<Float>,
        streetColor: SIMD4<Float>? = nil,
        farColor: SIMD4<Float>? = nil,
        farStreetColor: SIMD4<Float>? = nil,
        lowZoomFadeMask: Float = 0.0,
        lineWidthPoints: Float = 0.0,
        dashLengthPoints: Float = 0.0,
        dashGapPoints: Float = 0.0,
        dashInTileUnits: Bool = false,
        minimumWidthPoints: Float = 0.0,
        maximumWidthPoints: Float = 0.0,
        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData,
        includeRoadLabelPath: Bool = false,
        linePlacement: LinePlacement = .ground,
        lineRenderPasses: [LineRenderPass] = [],
        roadClassPriority: Int = 0,
        usesExtrusion: Bool = false,
        extrusionHeightScale: Float = 1.0,
        extrusionAnchorZoom: Int = 16,
        extrusionFallbackHeight: Float = 0,
        labelTextStyle: LabelTextStyle? = nil,
        roadLabelTextStyle: LabelTextStyle? = nil,
        roadDecorationKind: TileMvtParser.RoadDecorationKind = .none,
        isRoadSurfaceArea: Bool = false,
        surfaceAreaCutsPaint: Bool = false,
        isShippedRoadPaint: Bool = false,
        labelMinCameraZoom: Float = 0,
        suppressPolygonFill: Bool = false,
        fillOutlineAntialiasing: Bool = false
    ) {
        self.key = key
        self.color = color
        self.streetColor = streetColor
        self.farColor = farColor
        self.farStreetColor = farStreetColor
        self.lowZoomFadeMask = lowZoomFadeMask
        self.lineWidthPoints = lineWidthPoints
        self.dashLengthPoints = dashLengthPoints
        self.dashGapPoints = dashGapPoints
        self.dashInTileUnits = dashInTileUnits
        self.minimumWidthPoints = minimumWidthPoints
        self.maximumWidthPoints = maximumWidthPoints
        self.parseGeometryStyleData = parseGeometryStyleData
        self.includeRoadLabelPath = includeRoadLabelPath
        self.linePlacement = linePlacement
        self.lineRenderPasses = lineRenderPasses
        self.roadClassPriority = roadClassPriority
        self.usesExtrusion = usesExtrusion
        self.extrusionHeightScale = extrusionHeightScale
        self.extrusionAnchorZoom = extrusionAnchorZoom
        self.extrusionFallbackHeight = extrusionFallbackHeight
        self.labelTextStyle = labelTextStyle
        self.roadLabelTextStyle = roadLabelTextStyle
        self.roadDecorationKind = roadDecorationKind
        self.isRoadSurfaceArea = isRoadSurfaceArea
        self.surfaceAreaCutsPaint = surfaceAreaCutsPaint
        self.isShippedRoadPaint = isShippedRoadPaint
        self.labelMinCameraZoom = labelMinCameraZoom
        self.suppressPolygonFill = suppressPolygonFill
        self.fillOutlineAntialiasing = fillOutlineAntialiasing
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
