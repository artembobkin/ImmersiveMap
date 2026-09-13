// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

public enum LabelFontWeight: UInt8, Sendable {
    case bold = 0
    case thin = 1
}

/// Where a line's geometry draws: with the ground fills, or in the bridge
/// overlay above the roads.
public enum LinePlacement: Sendable {
    case ground
    case bridgeOverlay
}

/// The passes a road is drawn in, bottom to top. A style states one
/// `LineRenderPass` per role it wants; the roads of a tile are then drawn
/// role by role, so every casing lies under every fill of its tier.
public enum RoadPassRole: Int, CaseIterable, Sendable {
    case shadow
    case casing
    case fill
    case detail
    case overlay
}

/// Which network a road belongs to on the ground. The automobile tier draws
/// above the pedestrian one, so a path ending against an avenue never lies
/// over its kerb and a path crossing a street never cuts the street's
/// casing. The style decides the tier per road class.
public enum RoadTier: Sendable {
    case pedestrian
    case automobile
}

/// How a label's text is drawn.
public struct LabelTextStyle: Sendable {
    /// The style identity the label's glyph runs are grouped by. Set by the
    /// `FeatureStyle` factories from the feature style's key; a style that
    /// builds its `FeatureStyle` by hand sets it itself.
    public var key: Int
    public var fillColor: SIMD3<Float>
    public var strokeColor: SIMD3<Float>
    /// Halo width as a fraction of the em, so that it tracks the text size
    /// instead of drifting: an absolute width makes the smallest labels carry
    /// the widest halo relative to their strokes.
    public var haloEm: Float
    /// Em size in layout points, not device pixels: the engine multiplies by
    /// the display's pixels-per-point at render time, so one value reads at
    /// the same physical size on a 2x desktop display and a 3x phone. Sizes
    /// below `LabelTypeScale.minimumSizePoints` are raised to it by the
    /// factories, the floor for type that is meant to be read.
    public var sizePoints: Float
    public var weight: LabelFontWeight

    public init(key: Int = 0,
                fillColor: SIMD3<Float>,
                strokeColor: SIMD3<Float>,
                haloEm: Float,
                sizePoints: Float,
                weight: LabelFontWeight) {
        self.key = key
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.haloEm = haloEm
        self.sizePoints = sizePoints
        self.weight = weight
    }

    /// Halo width in device pixels for this style at a given screen scale.
    func haloWidthPixels(screenScale: ScreenScale) -> Float {
        screenScale.pixels(haloEm * sizePoints)
    }
}

/// One pass of a line: what the tessellator bakes (the geometry) and what
/// the shader draws it with.
public struct LineRenderPass: Sendable {
    public let key: UInt8
    public let color: SIMD4<Float>
    public let lowZoomFadeMask: Float
    /// Point-locked visible line width (full width, layout points). Zero keeps
    /// the world-locked behavior: the visible edge is the tessellated width.
    /// Non-zero resolves the edge in screen space at render time, so the width
    /// holds steady through fractional zoom instead of pumping with the tile's
    /// on-screen scale; the tessellated width then only bounds how wide the
    /// line can get. See `tileLineCoverage` in Tile.metal.
    public let lineWidthPoints: Float
    /// Point-locked dash pattern (layout points), cut per fragment from the
    /// vertices' arc-length parameter, so dashes hold their on-screen size at
    /// every zoom. Zero dash length draws solid. A pass with a point dash is
    /// tessellated as a continuous line: the unit-based dash fields of
    /// `lineGeometry` must stay zero for it.
    public let dashLengthPoints: Float
    public let dashGapPoints: Float
    /// True when `dashLengthPoints`/`dashGapPoints` are tile units rather
    /// than points: a world-locked pattern, paint on the ground whose period
    /// is a length and must not re-flow with the camera or the serving tile
    /// level. See `TileLineStyle.dashInTileUnits`.
    public let dashInTileUnits: Bool
    /// Floor for a world-locked width; see `TileLineStyle.minimumWidthPoints`.
    public let minimumWidthPoints: Float
    /// Symbol ceiling for a world-locked width; see
    /// `TileLineStyle.maximumWidthPoints`.
    public let maximumWidthPoints: Float
    /// Street-palette counterpart of `color` for passes whose color changes
    /// with the overview-to-street handover (the motorway accent); nil bakes
    /// `color` twice.
    public let streetColor: SIMD4<Float>?
    public let lineGeometry: LineGeometryStyle
    public let includeRoadLabelPath: Bool
    public let placement: LinePlacement
    public let roadPassRole: RoadPassRole

    public init(key: UInt8,
                color: SIMD4<Float>,
                streetColor: SIMD4<Float>? = nil,
                lowZoomFadeMask: Float = 0.0,
                lineWidthPoints: Float = 0.0,
                dashLengthPoints: Float = 0.0,
                dashGapPoints: Float = 0.0,
                dashInTileUnits: Bool = false,
                minimumWidthPoints: Float = 0.0,
                maximumWidthPoints: Float = 0.0,
                lineGeometry: LineGeometryStyle,
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
        self.lineGeometry = lineGeometry
        self.includeRoadLabelPath = includeRoadLabelPath
        self.placement = placement
        self.roadPassRole = roadPassRole
    }
}

/// How one feature draws: the style's whole answer, which the parser bakes
/// and the renderer draws. The factories below cover the common drawing
/// modes; the memberwise initializer exposes every knob.
///
/// `key` is the style's identity within a tile and its place in the draw
/// order: the ground fills of a tile draw in ascending key, and every
/// feature with the same key shares one style table entry. Key 0 hides the
/// feature.
public struct FeatureStyle: Sendable {
    public let key: UInt8
    public let color: SIMD4<Float>
    /// Street-palette counterpart of `color` for ground styles that change
    /// with the overview-to-street handover; nil bakes `color` twice. See
    /// `TilePolygonStyle.streetColor`.
    public let streetColor: SIMD4<Float>?
    /// The footprint fade target of a ground fill, the same globe/street
    /// pair, with the fade strength in the alpha; nil never fades. See
    /// `TilePolygonStyle.farColor`.
    public let farColor: SIMD4<Float>?
    public let farStreetColor: SIMD4<Float>?
    public let lowZoomFadeMask: Float
    /// See `LineRenderPass.lineWidthPoints`; zero for world-locked lines and
    /// for all polygon geometry.
    public let lineWidthPoints: Float
    /// See `LineRenderPass.dashLengthPoints`.
    public let dashLengthPoints: Float
    public let dashGapPoints: Float
    /// See `LineRenderPass.dashInTileUnits`.
    public let dashInTileUnits: Bool
    /// See `TileLineStyle.minimumWidthPoints`.
    public let minimumWidthPoints: Float
    /// See `TileLineStyle.maximumWidthPoints`.
    public let maximumWidthPoints: Float
    public let lineGeometry: LineGeometryStyle
    public let includeRoadLabelPath: Bool
    public let linePlacement: LinePlacement
    public let lineRenderPasses: [LineRenderPass]
    public let roadClassPriority: Int
    /// What the feature is as a building, nil for a polygon that is not
    /// raised. The style reads it from the tile's tags; the parser turns it
    /// into the extrusion.
    public let building: ImmersiveMapBuildingExtrusion?
    public var usesExtrusion: Bool { building != nil }
    public let extrusionHeightScale: Float
    public let extrusionAnchorZoom: Int
    public let extrusionFallbackHeight: Float
    public let labelTextStyle: LabelTextStyle?
    public let roadLabelTextStyle: LabelTextStyle?
    public let roadDecorationKind: RoadDecorationKind
    /// A polygon that is a carriageway surface (a junction area the tiles
    /// ship for a junction OSM maps as `area:highway`): it draws in the
    /// automobile road phases, its fill as the carriageway and its outline as
    /// the kerb, ordered among the roads so the surface covers the kerbs of
    /// every ribbon that enters it. False for every ground polygon.
    public let isRoadSurfaceArea: Bool
    /// Whether this surface also cuts the PAINT of the roads inside it, on
    /// top of cutting their ribbons. True for a junction reconstructed from
    /// the road graph: there is no lane paint inside a crossing. False for a
    /// hand-mapped `area:highway`, which typically covers a whole street's
    /// carriageway: the street keeps its paint, drawn over the surface.
    public let surfaceAreaCutsPaint: Bool
    /// Paint the source measured on the ground and shipped as its own line
    /// (`marking=...`): a lane line, a stop line, a crossing. It already ends
    /// exactly where it ends on the ground, so the engine's road machinery
    /// must not touch it: no clipping against carriageway surfaces, no
    /// junction making, no stitching, no junction inset (its passes carry
    /// `endInset` zero). False for every line the engine draws from a road's
    /// own geometry.
    public let isShippedRoadPaint: Bool
    /// Minimum CAMERA zoom for this feature's point label (0 = always visible).
    /// Travels with the label to runtime, where it is compared against the current camera zoom.
    public let labelMinCameraZoom: Float
    /// A line style (e.g. a border) must not fill areal geometry: some layer
    /// features arrive as polygons (Native American reservations in `boundary`),
    /// and filling them with the line color is wrong. The parser skips the
    /// polygon geometry of such features, keeping only the lines.
    public let suppressPolygonFill: Bool
    /// A plain fill whose ring edges are antialiased by the fill-outline
    /// pass: the parser keeps the fill's ring edges as a line list and the
    /// flat drawer rasterizes them as one-pixel lines in the fill's colour,
    /// with alpha by distance to the edge, over the fill's own staircase
    /// (`ParsedPolygon.outlineIndices`). Fills only; a line style or an
    /// extruded polygon leaves it false.
    public let fillOutlineAntialiasing: Bool
    /// The network the road draws in (see `RoadTier`). Set by the style, read
    /// by the road readers when they order ribbons and stitch streets.
    public var roadTier: RoadTier = .pedestrian
    /// Whether the road makes a junction for the paint on another road: a
    /// lane line running into it stops short of the crossing. True for a
    /// street, false for a way onto a plot (a driveway, a parking aisle, a
    /// footway) and for shipped paint, which is not a street at all.
    public var roadMakesJunctions: Bool = false
    /// A point label that names a body of water. The parser adds ocean and
    /// sea names of its own at the coarse zooms, and skips any the tile
    /// already labels; this is how it recognises those.
    public var isWaterName: Bool = false
    /// What the feature is as a road: where it sits and which street it is
    /// a piece of. `ground` for everything that is not a road.
    public var road: ImmersiveMapRoadFacts = .ground
    /// The feature draws the tunnel look: a road tagged as a tunnel, or a
    /// carriageway surface the parser found to be a tunnel's roof. Only a
    /// road like this marks the surfaces it runs inside as tunnel roofs,
    /// and a tunnel surface clips every line of shipped paint inside it.
    public var drawsAsTunnel: Bool = false
    /// A parking lot whose bays are parallel to the kerb (a car length
    /// apart) rather than perpendicular to it.
    public var parkingBaysParallel: Bool = false
    /// A fill whose polygons with many holes (an ocean with its islands)
    /// are not tessellated as one polygon: the exterior draws as the fill
    /// and each hole as the background, so the tessellator never sees the
    /// hundreds of islands of a coastal tile at once.
    public var splitsComplexHoles: Bool = false

    public init(
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
        lineGeometry: LineGeometryStyle,
        includeRoadLabelPath: Bool = false,
        linePlacement: LinePlacement = .ground,
        lineRenderPasses: [LineRenderPass] = [],
        roadClassPriority: Int = 0,
        building: ImmersiveMapBuildingExtrusion? = nil,
        extrusionHeightScale: Float = 1.0,
        extrusionAnchorZoom: Int = 16,
        extrusionFallbackHeight: Float = 0,
        labelTextStyle: LabelTextStyle? = nil,
        roadLabelTextStyle: LabelTextStyle? = nil,
        roadDecorationKind: RoadDecorationKind = .none,
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
        self.lineGeometry = lineGeometry
        self.includeRoadLabelPath = includeRoadLabelPath
        self.linePlacement = linePlacement
        self.lineRenderPasses = lineRenderPasses
        self.roadClassPriority = roadClassPriority
        self.building = building
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
}

// MARK: - The common drawing modes

public extension FeatureStyle {
    /// Nothing is drawn.
    static let hidden = FeatureStyle(key: 0,
                                     color: SIMD4<Float>(0, 0, 0, 0),
                                     lineGeometry: LineGeometryStyle(lineWidth: 0))

    /// A fill, with its ring edges antialiased.
    static func polygon(key: UInt8, color: SIMD4<Float>) -> FeatureStyle {
        FeatureStyle(key: key,
                     color: color,
                     lineGeometry: LineGeometryStyle(lineWidth: 100),
                     fillOutlineAntialiasing: true)
    }

    /// A line of a width in tile units. `road` is what the feature is as a
    /// road (where it sits, which street it is a piece of), read by the
    /// style from the tile: `ImmersiveMapRoadFacts.openStreetMap(_:)` for
    /// a schema carrying the OpenStreetMap tags, `.ground` for a line that
    /// is not a road or whose schema says nothing about it.
    static func line(key: UInt8,
                     color: SIMD4<Float>,
                     width: Float,
                     road: ImmersiveMapRoadFacts = .ground) -> FeatureStyle {
        var style = FeatureStyle(key: key,
                                 color: color,
                                 lineGeometry: LineGeometryStyle(lineWidth: Double(max(Float(0), width))))
        style.road = road
        style.drawsAsTunnel = road.structure == .tunnel
        return style
    }

    /// A line whose width is stated in on-screen points and held there at
    /// every zoom: the drawing mode the built-in style uses for country
    /// borders and for the overview road skeleton. The stroke is opaque from
    /// the first frame it is visible, ends in butt caps with plain joins, and
    /// an optional dash pattern is stated in points too, so it reads as
    /// dashes at every zoom. Suited to symbolic lines (borders, networks over
    /// a country view) whose weight is a design decision rather than a width
    /// on the ground; `line` stays the world-locked line whose width lives in
    /// tile units. Areal geometry a source ships under this mode is not
    /// filled: only the outlines draw.
    static func pointLockedLine(key: UInt8,
                                color: SIMD4<Float>,
                                widthPoints: Float,
                                dashLengthPoints: Float = 0,
                                dashGapPoints: Float = 0,
                                road: ImmersiveMapRoadFacts = .ground) -> FeatureStyle {
        var style = FeatureStyle.pointLockedLine(key: key,
                                                 color: color,
                                                 widthPoints: max(0, widthPoints),
                                                 dashLengthPoints: max(0, dashLengthPoints),
                                                 dashGapPoints: max(0, dashGapPoints),
                                                 suppressPolygonFill: true)
        style.road = road
        style.drawsAsTunnel = road.structure == .tunnel
        return style
    }

    /// A building. What the feature is as a building (its height, its base,
    /// the building it belongs to, its roof) is the style's reading of the
    /// tile's tags: `ImmersiveMapBuildingExtrusion.openStreetMap(_:)` for
    /// a schema carrying the OpenStreetMap tags, or the fields stated from
    /// another schema's tags. `heightScale`, `anchorZoom` and
    /// `fallbackHeight` say how metres become tile units and what a
    /// building without a height gets.
    static func extrudedPolygon(key: UInt8,
                                color: SIMD4<Float>,
                                building: ImmersiveMapBuildingExtrusion,
                                heightScale: Float = 1.0,
                                anchorZoom: Int = 16,
                                fallbackHeight: Float = 0) -> FeatureStyle {
        FeatureStyle(key: key,
                     color: color,
                     lineGeometry: LineGeometryStyle(lineWidth: 100),
                     building: building,
                     extrusionHeightScale: heightScale,
                     extrusionAnchorZoom: anchorZoom,
                     extrusionFallbackHeight: fallbackHeight)
    }

    /// A point label. The text comes from the label profile; this says how
    /// it is drawn, and from which camera zoom.
    static func pointLabel(key: UInt8,
                           _ textStyle: LabelTextStyle,
                           minCameraZoom: Float = 0) -> FeatureStyle {
        FeatureStyle(key: key,
                     color: SIMD4<Float>(0, 0, 0, 0),
                     lineGeometry: LineGeometryStyle(lineWidth: 0),
                     labelTextStyle: Self.keyed(textStyle, key: key),
                     labelMinCameraZoom: minCameraZoom)
    }

    /// A road drawn as a line of a width in tile units, with its name laid
    /// along it.
    static func roadLabel(key: UInt8,
                          color: SIMD4<Float>,
                          width: Float,
                          textStyle: LabelTextStyle,
                          road: ImmersiveMapRoadFacts = .ground) -> FeatureStyle {
        var style = FeatureStyle(key: key,
                                 color: color,
                                 lineGeometry: LineGeometryStyle(lineWidth: Double(max(Float(0), width))),
                                 includeRoadLabelPath: true,
                                 roadLabelTextStyle: Self.keyed(textStyle, key: key))
        style.road = road
        style.drawsAsTunnel = road.structure == .tunnel
        return style
    }

    /// The text style under the feature style's key, with the size floor
    /// applied.
    private static func keyed(_ textStyle: LabelTextStyle, key: UInt8) -> LabelTextStyle {
        var keyed = textStyle
        keyed.key = Int(key)
        keyed.sizePoints = LabelTypeScale.clamped(textStyle.sizePoints)
        return keyed
    }
}
