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

/// The passes a road is drawn in, bottom to top. A `RoadStyle` states one
/// stroke per role it wants (any number of paint strokes); the roads of a
/// tile are then drawn role by role, so every casing lies under every fill
/// of its tier.
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

/// Where a road draws in the road stack: tunnels under everything on the
/// ground, bridges over everything. The style decides from the facts (a
/// road in a tunnel, a road diving under a bridge with only a negative
/// `layer`, a ramp with a positive one).
public enum RoadLevel: Sendable {
    case tunnel
    case ground
    case bridge
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

/// One stroke of a line: what the tessellator bakes (the geometry) and
/// what the shader draws it with. A plain line is one stroke; a road is a
/// stroke per role.
///
/// `key` is the stroke's identity within a tile and its place in the draw
/// order: the ground geometry of a tile draws in ascending key, and every
/// feature with the same key shares one style table entry.
public struct LinePass: Sendable {
    /// How a point-locked width comes in with the camera: `startWidthPoints`
    /// wide, at `startAlpha` of the colour's alpha, up to `startZoom`, and
    /// the stroke's own `lineWidthPoints` and alpha from `endZoom`. Between
    /// the two the width grows by the same ratio per zoom level and the
    /// alpha linearly, both continuous in camera zoom. The ramp is a
    /// function of the camera alone, so two tile levels that state the same
    /// ramp draw the same stroke, and the swap between them shows nothing.
    public struct WidthRamp: Sendable, Equatable {
        public var startWidthPoints: Float
        public var startZoom: Float
        public var endZoom: Float
        public var startAlpha: Float

        public init(startWidthPoints: Float, startZoom: Float, endZoom: Float, startAlpha: Float = 1) {
            self.startWidthPoints = startWidthPoints
            self.startZoom = startZoom
            self.endZoom = endZoom
            self.startAlpha = startAlpha
        }

        /// The width at a camera zoom, for a stroke `endWidthPoints` wide.
        public func widthPoints(atZoom zoom: Float, endWidthPoints: Float) -> Float {
            guard endZoom > startZoom, startWidthPoints > 0, endWidthPoints > 0 else { return endWidthPoints }
            let progress = min(max((zoom - startZoom) / (endZoom - startZoom), 0), 1)
            return startWidthPoints * Float(pow(Double(endWidthPoints / startWidthPoints), Double(progress)))
        }
    }

    public var key: UInt8
    public var color: SIMD4<Float>
    /// How the stroke appears or disappears with the camera zoom.
    public var zoomFade: ImmersiveMapZoomFade
    /// Point-locked visible line width (full width, layout points). Zero keeps
    /// the world-locked behavior: the visible edge is the tessellated width.
    /// Non-zero resolves the edge in screen space at render time, so the width
    /// holds steady through fractional zoom instead of pumping with the tile's
    /// on-screen scale; the tessellated width then only bounds how wide the
    /// line can get. See `tileLineCoverage` in Tile.metal.
    public var lineWidthPoints: Float
    /// Point-locked dash pattern (layout points), cut per fragment from the
    /// vertices' arc-length parameter, so dashes hold their on-screen size at
    /// every zoom. Zero dash length draws solid. A stroke with a point dash
    /// is tessellated as a continuous line: the unit-based dash fields of
    /// `lineGeometry` must stay zero for it.
    public var dashLengthPoints: Float
    public var dashGapPoints: Float
    /// True when `dashLengthPoints`/`dashGapPoints` are tile units rather
    /// than points: a world-locked pattern, paint on the ground whose period
    /// is a length and must not re-flow with the camera or the serving tile
    /// level. See `TileLineStyle.dashInTileUnits`.
    public var dashInTileUnits: Bool
    /// Floor for a world-locked width; see `TileLineStyle.minimumWidthPoints`.
    public var minimumWidthPoints: Float
    /// The camera zoom from which a point-locked width (`lineWidthPoints`)
    /// is fixed on the ground instead of on screen. Up to this zoom the
    /// stroke is a symbol, as wide in points as the style says. Past it the
    /// stroke keeps the ground width those points had at this zoom, so it
    /// grows on screen with the map and never thins into a hairline against
    /// the buildings around it. Continuous in camera zoom by construction.
    /// Zero keeps the width in points at every zoom.
    public var pointWidthWorldLockZoom: Float
    /// The zoom ramp `lineWidthPoints` comes in over; nil holds the width at
    /// every zoom up to the world lock.
    public var pointWidthRamp: WidthRamp?
    public var lineGeometry: LineGeometryStyle

    public init(key: UInt8,
                color: SIMD4<Float>,
                zoomFade: ImmersiveMapZoomFade = .none,
                lineWidthPoints: Float = 0.0,
                dashLengthPoints: Float = 0.0,
                dashGapPoints: Float = 0.0,
                dashInTileUnits: Bool = false,
                minimumWidthPoints: Float = 0.0,
                pointWidthWorldLockZoom: Float = 0.0,
                pointWidthRamp: WidthRamp? = nil,
                lineGeometry: LineGeometryStyle) {
        self.key = key
        self.color = color
        self.zoomFade = zoomFade
        self.lineWidthPoints = lineWidthPoints
        self.dashLengthPoints = dashLengthPoints
        self.dashGapPoints = dashGapPoints
        self.dashInTileUnits = dashInTileUnits
        self.minimumWidthPoints = minimumWidthPoints
        self.pointWidthWorldLockZoom = pointWidthWorldLockZoom
        self.pointWidthRamp = pointWidthRamp
        self.lineGeometry = lineGeometry
    }
}

/// A ground fill.
public struct FillStyle: Sendable {
    public var key: UInt8
    public var color: SIMD4<Float>
    /// How the fill appears or disappears with the camera zoom.
    public var zoomFade: ImmersiveMapZoomFade
    /// A fill whose polygons with many holes (an ocean with its islands)
    /// are not tessellated as one polygon: the exterior draws as the fill
    /// and each hole as the background, so the tessellator never sees the
    /// hundreds of islands of a coastal tile at once.
    public var splitsComplexHoles: Bool
    /// A fill that takes its place among the ground lines by its key. The
    /// ground draws every fill first and every line over them, so a plain
    /// fill lies under every river and ferry route whatever its key. A
    /// fill that must cover such lines (a bridge's deck over the river)
    /// draws with the lines instead, over those of a lower key and under
    /// those of a higher one, and over every plain fill.
    public var drawsAmongGroundLines: Bool

    public init(key: UInt8,
                color: SIMD4<Float>,
                zoomFade: ImmersiveMapZoomFade = .none,
                splitsComplexHoles: Bool = false,
                drawsAmongGroundLines: Bool = false) {
        self.key = key
        self.color = color
        self.zoomFade = zoomFade
        self.splitsComplexHoles = splitsComplexHoles
        self.drawsAmongGroundLines = drawsAmongGroundLines
    }
}

/// A line that is not a road: one stroke, with no place in the road order.
public struct LineStyle: Sendable {
    public var pass: LinePass
    public var placement: LinePlacement
    /// Whether areal geometry a source ships under this style is filled
    /// with the stroke's colour. False draws only lines: a border style
    /// must not fill the reservations that arrive as polygons in the same
    /// layer.
    public var fillsAreas: Bool

    public init(pass: LinePass, placement: LinePlacement = .ground, fillsAreas: Bool = true) {
        self.pass = pass
        self.placement = placement
        self.fillsAreas = fillsAreas
    }
}

/// A road: a line drawn in the road order. One stroke per role, bottom to
/// top (`shadow`, `casing`, `fill`, the `paint` on the surface,
/// `overlay`), plus what the engine's road work needs to know about the
/// road as the style sees it: where it sorts, which tier it draws in,
/// what figure is stamped along it, and the name laid along it.
public struct RoadStyle: Sendable {
    public var shadow: LinePass?
    public var casing: LinePass?
    public var fill: LinePass?
    /// The strokes painted on the surface, drawn in the `detail` role above
    /// every fill: the stroke a decoration is stamped in.
    public var paint: [LinePass]
    public var overlay: LinePass?
    /// The road's place among the roads of its level: higher draws over
    /// lower.
    public var classPriority: Int
    /// Where the road draws in the stack (see `RoadLevel`).
    public var level: RoadLevel
    /// The network the road draws in on the ground (see `RoadTier`).
    public var tier: RoadTier
    /// The figure stamped along the geometry instead of a plain stroke.
    public var decoration: RoadDecorationKind
    /// The name laid along the road, nil for a road that carries none.
    public var label: LabelTextStyle?
    public var placement: LinePlacement

    public init(shadow: LinePass? = nil,
                casing: LinePass? = nil,
                fill: LinePass? = nil,
                paint: [LinePass] = [],
                overlay: LinePass? = nil,
                classPriority: Int = 0,
                level: RoadLevel = .ground,
                tier: RoadTier = .pedestrian,
                decoration: RoadDecorationKind = .none,
                label: LabelTextStyle? = nil,
                placement: LinePlacement = .ground) {
        self.shadow = shadow
        self.casing = casing
        self.fill = fill
        self.paint = paint
        self.overlay = overlay
        self.classPriority = classPriority
        self.level = level
        self.tier = tier
        self.decoration = decoration
        self.label = label
        self.placement = placement
    }

    /// One stroke with its role.
    public struct Pass: Sendable {
        public let role: RoadPassRole
        public let pass: LinePass
    }

    /// Every stroke the road draws, bottom to top.
    public var orderedPasses: [Pass] {
        var passes: [Pass] = []
        if let shadow { passes.append(Pass(role: .shadow, pass: shadow)) }
        if let casing { passes.append(Pass(role: .casing, pass: casing)) }
        if let fill { passes.append(Pass(role: .fill, pass: fill)) }
        for stroke in paint { passes.append(Pass(role: .detail, pass: stroke)) }
        if let overlay { passes.append(Pass(role: .overlay, pass: overlay)) }
        return passes
    }

    /// The road's identity within a tile: the fill's key, or the first
    /// stroke's for a road that is paint alone.
    public var key: UInt8 {
        fill?.key ?? orderedPasses.first?.pass.key ?? 0
    }
}

/// A building: the footprint raised to the heights the schema reading
/// states for it (`ImmersiveMapFeatureFacts.building`). The footprint also
/// draws as a ground fill in the same colour, whether or not it rises.
public struct ExtrusionStyle: Sendable {
    public var key: UInt8
    public var color: SIMD4<Float>
    /// How metres become tile units at `anchorZoom`; the parser doubles the
    /// scale per zoom level above it and halves it below.
    public var heightScale: Float
    public var anchorZoom: Int
    /// The height in metres of a building the reading states no height
    /// for; zero leaves it flat.
    public var fallbackHeight: Float
    public init(key: UInt8,
                color: SIMD4<Float>,
                heightScale: Float = 1.0,
                anchorZoom: Int = 16,
                fallbackHeight: Float = 0) {
        self.key = key
        self.color = color
        self.heightScale = heightScale
        self.anchorZoom = anchorZoom
        self.fallbackHeight = fallbackHeight
    }
}

/// A point label. The text is the name the schema reading states, in the
/// map's language; this says how it is drawn and how important it is.
public struct PointLabelStyle: Sendable {
    public var key: UInt8
    public var text: LabelTextStyle
    /// The label's importance among the labels of the map, lower first: the
    /// order the runtime reveals labels in as room appears, and deduplicates
    /// them in. The built-in style reads it from the tiles' rank.
    public var rank: Int
    /// The label's precedence when two labels overlap, lower wins. Usually
    /// the rank offset by layer, so a place name beats a shop's.
    public var collisionRank: Int
    /// Minimum CAMERA zoom for the label (0 = always visible). Travels with
    /// the label to runtime, where it is compared against the camera zoom.
    public var minCameraZoom: Float
    /// The sprite drawn beside the text, nil for text alone.
    public var icon: PoiSpriteIcon?
    /// Upright on the screen, or painted on the map. A label painted on the
    /// map draws its text alone: the icon, the ranks and the minimum camera
    /// zoom belong to the screen labels.
    public var placement: LabelPlacement

    public init(key: UInt8,
                text: LabelTextStyle,
                rank: Int = 0,
                collisionRank: Int? = nil,
                minCameraZoom: Float = 0,
                icon: PoiSpriteIcon? = nil,
                placement: LabelPlacement = .screen) {
        self.key = key
        self.text = text
        self.rank = rank
        self.collisionRank = collisionRank ?? rank
        self.minCameraZoom = minCameraZoom
        self.icon = icon
        self.placement = placement
    }
}

/// How one feature draws: the style's whole answer, which the parser bakes
/// and the renderer draws. One case per drawing mode, each carrying only
/// the knobs that mode has: a reader switches over the case and cannot
/// read a label's fields off a fill. What the feature is (a road in a
/// tunnel, a building of some height) is not in
/// here: that is the schema reading's `ImmersiveMapFeatureFacts`, which the
/// parser carries next to the style.
///
/// The factories below cover the common cases; the payload initializers
/// expose every knob.
public enum FeatureStyle: Sendable {
    /// Nothing is drawn.
    case hidden
    case fill(FillStyle)
    case line(LineStyle)
    case road(RoadStyle)
    case extrusion(ExtrusionStyle)
    case pointLabel(PointLabelStyle)

    /// The style's identity within a tile, 0 for `hidden`.
    public var key: UInt8 {
        switch self {
        case .hidden: return 0
        case .fill(let fill): return fill.key
        case .line(let line): return line.pass.key
        case .road(let road): return road.key
        case .extrusion(let extrusion): return extrusion.key
        case .pointLabel(let label): return label.key
        }
    }

    public var fillStyle: FillStyle? {
        if case .fill(let fill) = self { return fill }
        return nil
    }

    public var lineStyle: LineStyle? {
        if case .line(let line) = self { return line }
        return nil
    }

    /// The style as a road: a `road` as it is, and a plain `line` as a
    /// road of one fill stroke with no class, so a line on a road layer
    /// takes the road path with the lowest priority.
    public var roadStyle: RoadStyle? {
        switch self {
        case .road(let road):
            return road
        case .line(let line):
            return RoadStyle(fill: line.pass, placement: line.placement)
        case .hidden, .fill, .extrusion, .pointLabel:
            return nil
        }
    }

    public var extrusionStyle: ExtrusionStyle? {
        if case .extrusion(let extrusion) = self { return extrusion }
        return nil
    }

    public var pointLabelStyle: PointLabelStyle? {
        if case .pointLabel(let label) = self { return label }
        return nil
    }
}

// MARK: - The common drawing modes

public extension FeatureStyle {
    /// A fill, drawn at its full alpha unless `zoomFade` says otherwise.
    static func polygon(key: UInt8,
                        color: SIMD4<Float>,
                        zoomFade: ImmersiveMapZoomFade = .none) -> FeatureStyle {
        .fill(FillStyle(key: key, color: color, zoomFade: zoomFade))
    }

    /// A line of a width in tile units.
    static func line(key: UInt8,
                     color: SIMD4<Float>,
                     width: Float,
                     zoomFade: ImmersiveMapZoomFade = .none) -> FeatureStyle {
        .line(LineStyle(pass: LinePass(key: key,
                                       color: color,
                                       zoomFade: zoomFade,
                                       lineGeometry: LineGeometryStyle(lineWidth: Double(max(Float(0), width))))))
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
                                zoomFade: ImmersiveMapZoomFade = .fadeIn(from: 0, to: 1)) -> FeatureStyle {
        .line(LineStyle(pass: LinePass.pointLocked(key: key,
                                                   color: color,
                                                   widthPoints: max(0, widthPoints),
                                                   dashLengthPoints: max(0, dashLengthPoints),
                                                   dashGapPoints: max(0, dashGapPoints),
                                                   zoomFade: zoomFade),
                        fillsAreas: false))
    }

    /// A building: the footprint raised to the heights the schema reading
    /// states for it (`ImmersiveMapFeatureFacts.building`). `heightScale`,
    /// `anchorZoom` and `fallbackHeight` say how metres become tile units
    /// and what a building without a height gets. A feature the reading
    /// found to be no building stays a flat fill.
    static func extrudedPolygon(key: UInt8,
                                color: SIMD4<Float>,
                                heightScale: Float = 1.0,
                                anchorZoom: Int = 16,
                                fallbackHeight: Float = 0) -> FeatureStyle {
        .extrusion(ExtrusionStyle(key: key,
                                  color: color,
                                  heightScale: heightScale,
                                  anchorZoom: anchorZoom,
                                  fallbackHeight: fallbackHeight))
    }

    /// A point label. The text is the name the schema reading states, in
    /// the map's language; this says how it is drawn, how important it is
    /// (`rank`, lower first, and `collisionRank`, which defaults to the
    /// rank), from which camera zoom, which sprite stands beside it, and
    /// whether it stands on the screen or lies on the map.
    static func pointLabel(key: UInt8,
                           _ textStyle: LabelTextStyle,
                           rank: Int = 0,
                           collisionRank: Int? = nil,
                           minCameraZoom: Float = 0,
                           icon: PoiSpriteIcon? = nil,
                           placement: LabelPlacement = .screen) -> FeatureStyle {
        .pointLabel(PointLabelStyle(key: key,
                                    text: Self.keyed(textStyle, key: key),
                                    rank: rank,
                                    collisionRank: collisionRank,
                                    minCameraZoom: minCameraZoom,
                                    icon: icon,
                                    placement: placement))
    }

    /// A road drawn as a line of a width in tile units, with its name laid
    /// along it.
    static func roadLabel(key: UInt8,
                          color: SIMD4<Float>,
                          width: Float,
                          textStyle: LabelTextStyle) -> FeatureStyle {
        .road(RoadStyle(fill: LinePass(key: key,
                                       color: color,
                                       lineGeometry: LineGeometryStyle(lineWidth: Double(max(Float(0), width)))),
                        label: Self.keyed(textStyle, key: key)))
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
