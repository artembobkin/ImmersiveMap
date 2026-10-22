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
/// tile are then stacked role by role, so every casing lies under every
/// fill of its tier.
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
    /// Whether the label is set in capitals. The text is uppercased when the
    /// name is resolved, before the atlas is asked whether it can render
    /// it, so a name whose capitals it lacks falls back like any other.
    public var uppercased: Bool
    /// How far the letters are grown past the font's outline, in layout
    /// points: a little weight that keeps small type solid over a busy map.
    /// Zero draws the face as the font designs it, and a negative value
    /// thins it.
    public var emboldenPoints: Float
    /// Extra room after every letter, in ems: the tracking a name spaced
    /// out over the land it names is set with, the way an atlas letters a
    /// country. Zero sets the letters as the font spaces them.
    public var letterSpacingEm: Float
    /// The opacity of the label, fill and halo alike, 0 to 1: a name laid
    /// over the land as lettering rather than a sign, letting the map
    /// show through. 1 is solid.
    public var opacity: Float
    /// The fill and the halo the label wears on the globe, nil for its own:
    /// the day's dark lettering under a night palette, so the planet keeps
    /// its daylight while the plane is dark. They hold through the globe's
    /// view, the unroll into the plane included, and are handed over to
    /// the label's own colours with the globe's air at the end of the
    /// unroll (`PresentationSettings.airHandoverStart` to
    /// `airHandoverEnd`), the way a fill's `FillStyle.sphereColor` is. The
    /// size, the weight, the halo's width and the opacity stay the label's
    /// own. Only the labels of the globe's zooms read them.
    public var sphereFillColor: SIMD3<Float>?
    public var sphereStrokeColor: SIMD3<Float>?

    /// The growth every label had before it was a style value: three
    /// quarters of a pixel on the 2x display the palette was authored on.
    public static let defaultEmboldenPoints: Float = 0.375

    public init(key: Int = 0,
                fillColor: SIMD3<Float>,
                strokeColor: SIMD3<Float>,
                haloEm: Float,
                sizePoints: Float,
                weight: LabelFontWeight,
                uppercased: Bool = false,
                emboldenPoints: Float = LabelTextStyle.defaultEmboldenPoints,
                letterSpacingEm: Float = 0,
                opacity: Float = 1,
                sphereFillColor: SIMD3<Float>? = nil,
                sphereStrokeColor: SIMD3<Float>? = nil) {
        self.key = key
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.haloEm = haloEm
        self.sizePoints = sizePoints
        self.weight = weight
        self.uppercased = uppercased
        self.emboldenPoints = emboldenPoints
        self.letterSpacingEm = letterSpacingEm
        self.opacity = opacity
        self.sphereFillColor = sphereFillColor
        self.sphereStrokeColor = sphereStrokeColor
    }

    /// The fill at a point of the globe's handover to the plane: the
    /// globe's at 0, the label's own at 1 and where it states no globe
    /// colour, mixed between.
    public func fillColor(atHandover handover: Float) -> SIMD3<Float> {
        Self.mix(sphereFillColor, fillColor, handover: handover)
    }

    /// The halo at a point of the globe's handover to the plane, as
    /// `fillColor(atHandover:)`.
    public func strokeColor(atHandover handover: Float) -> SIMD3<Float> {
        Self.mix(sphereStrokeColor, strokeColor, handover: handover)
    }

    private static func mix(_ sphere: SIMD3<Float>?, _ own: SIMD3<Float>, handover: Float) -> SIMD3<Float> {
        guard let sphere else {
            return own
        }
        let t = min(max(handover, 0), 1)
        return sphere + (own - sphere) * t
    }

    /// Halo width in device pixels for this style at a given screen scale.
    func haloWidthPixels(screenScale: ScreenScale) -> Float {
        screenScale.pixels(haloEm * sizePoints)
    }

    /// The growth of the letters in device pixels at a given screen scale.
    func emboldenPixels(screenScale: ScreenScale) -> Float {
        screenScale.pixels(emboldenPoints)
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
    /// The share of the colour's alpha the stroke keeps on the globe, in
    /// `0...1`: one, the default, is the same stroke on both surfaces, and
    /// less is a veil the globe's view lays over it, so the ground stays
    /// the picture of a continent and the roads a net over it. The veil
    /// holds through the globe's view, the unroll into the plane included,
    /// is handed over to the plane's with the globe's air at the end of
    /// the unroll (`PresentationSettings.airHandoverStart` to
    /// `airHandoverEnd`), and the plane never has it. Only the sphere's
    /// ribbons read it: a road of the street zooms is never on the sphere.
    public var sphereAlpha: Float
    /// The colour the stroke wears on the globe, nil for its own: an
    /// atlas's highway yellow over the painted globe where the plane draws
    /// asphalt. Handed over with `sphereAlpha`. Only the sphere's ribbons
    /// read it.
    public var sphereColor: SIMD3<Float>?
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
                sphereAlpha: Float = 1,
                sphereColor: SIMD3<Float>? = nil,
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
        self.sphereAlpha = sphereAlpha
        self.sphereColor = sphereColor
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
    /// The colour the fill wears on the globe, nil for its own: the day's
    /// ocean under a night palette, so the planet keeps its daylight while
    /// the plane is dark. It holds through the globe's view, the unroll
    /// into the plane included, and is handed over to the fill's own
    /// colour with the globe's air at the end of the unroll
    /// (`PresentationSettings.airHandoverStart` to `airHandoverEnd`), the
    /// way a stroke's `LinePass.sphereColor` is. The alpha stays the
    /// fill's own. Only the sphere's fills read it: a fill of the street
    /// zooms is never on the sphere.
    public var sphereColor: SIMD3<Float>?
    /// The trees the fill grows on the flat map, nil for none: a wood or
    /// a park stands the engine's tree over its polygons (`TreeFillStyle`).
    public var trees: TreeFillStyle?
    /// A fill no tree stands on, whatever fill it lies in: the water, a
    /// pond in a park, a pitch or a lawn. The trees of the fills around
    /// it keep off its polygons, an island in a lake excepted.
    public var excludesTrees: Bool

    public init(key: UInt8,
                color: SIMD4<Float>,
                zoomFade: ImmersiveMapZoomFade = .none,
                splitsComplexHoles: Bool = false,
                drawsAmongGroundLines: Bool = false,
                sphereColor: SIMD3<Float>? = nil,
                trees: TreeFillStyle? = nil,
                excludesTrees: Bool = false) {
        self.key = key
        self.color = color
        self.zoomFade = zoomFade
        self.splitsComplexHoles = splitsComplexHoles
        self.drawsAmongGroundLines = drawsAmongGroundLines
        self.sphereColor = sphereColor
        self.trees = trees
        self.excludesTrees = excludesTrees
    }
}

/// The trees a fill grows: the engine stands its tree model on a lattice
/// over the fill's polygons, one tree at most in every cell, each moved
/// within its cell, turned and sized by a hash of the cell, so the same
/// ground grows the same trees at every parse (`TreeScatter`). The trees
/// draw on the flat map from the camera zoom the settings name
/// (`ImmersiveMapSettings.TreeSettings`), thinned at the first zooms, and
/// keep off the buildings' footprints and the roads. Baked into the
/// prepared tiles with the rest of the style, so a change re-parses them.
public struct TreeFillStyle: Sendable, Equatable {
    /// The distance between neighbouring trees in metres, the lattice's
    /// cell: 9 for a wood whose crowns touch, 20 and more for the
    /// scattered trees of a park.
    public var spacingMetres: Float
    /// The height of the shortest and the tallest tree in metres: every
    /// tree takes its own height between the two.
    public var minimumHeightMetres: Float
    public var maximumHeightMetres: Float
    /// How far from a road's edge a tree keeps, in metres, beyond the
    /// road's own width as the style draws it: the verge no trunk stands
    /// on, whatever the fill says. Every road of the ground counts, a
    /// park's paths among them, not the tunnels and the bridges. 3 by
    /// default.
    public var roadClearanceMetres: Float

    public init(spacingMetres: Float, heightMetres: ClosedRange<Float>, roadClearanceMetres: Float = 3) {
        self.spacingMetres = max(spacingMetres, 0.5)
        self.minimumHeightMetres = max(heightMetres.lowerBound, 0)
        self.maximumHeightMetres = max(heightMetres.upperBound, self.minimumHeightMetres)
        self.roadClearanceMetres = max(roadClearanceMetres, 0)
    }

    /// The lattice's salt: fills of different spacing hash their cells
    /// apart, so a park inside a wood grows its own trees.
    var lattice: UInt32 {
        spacingMetres.bitPattern
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
/// what figure is stamped along it, the name laid along it and the signs of
/// its routes.
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
    /// The signs of the routes the road carries, nil for a road that
    /// carries none.
    public var shields: RouteShieldStyle?
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
                shields: RouteShieldStyle? = nil,
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
        self.shields = shields
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
    /// The radius, in metres, the building's edges are rounded by: every
    /// corner of its footprint and the rim of its roof take a narrow bevel
    /// whose shading runs from one face into the next, so a block reads as
    /// a soft solid rather than a sharp box. Zero keeps the sharp box. A
    /// building too small or too low for the radius takes a smaller one.
    /// Baked into the prepared tiles with the rest of the style.
    public var edgeRadius: Float
    public init(key: UInt8,
                color: SIMD4<Float>,
                heightScale: Float = 1.0,
                anchorZoom: Int = 16,
                fallbackHeight: Float = 0,
                edgeRadius: Float = 0) {
        self.key = key
        self.color = color
        self.heightScale = heightScale
        self.anchorZoom = anchorZoom
        self.fallbackHeight = fallbackHeight
        self.edgeRadius = edgeRadius
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
    /// The camera zoom the label goes away at: shown while the camera zoom
    /// is below it, hidden from it on. Infinity shows the label at every
    /// zoom past its minimum. A country's name is read over the country
    /// and says nothing among the streets of one of its towns.
    public var maxCameraZoom: Float
    /// The sprite drawn beside the text, nil for text alone.
    public var icon: PoiSpriteIcon?
    /// Upright on the screen, or painted on the map. A label painted on the
    /// map draws its text alone: the icon, the ranks and the minimum camera
    /// zoom belong to the screen labels.
    public var placement: LabelPlacement
    /// Whether a screen label standing inside an extruded building belongs
    /// to it. The label takes the roof over its anchor, the top of the
    /// tallest volume whose footprint holds it (or of the model drawn in
    /// its place), wherever the frame draws that building. A label naming
    /// the building itself, the same OSM element as the building, rises to
    /// the roof, and one naming something inside it stays on the ground.
    /// On the ground where the frame draws no buildings (the globe, a zoom
    /// coarser than the building tiles, beyond the near field).
    public var standsOnRoof: Bool
    /// Whether the label is local detail, shown only near the camera: the
    /// house numbers, a memorial's plaque, a ticket office, the things one
    /// reads standing next to them. It keeps to the three by three tiles
    /// around the one the camera looks at, and within them to
    /// `BaseSettings.localDetailMaximumDistanceMeters` from the camera, so
    /// on a tilted map the detail up the street, where it would be a
    /// scatter of small text saying nothing, is left out.
    public var isLocal: Bool

    public init(key: UInt8,
                text: LabelTextStyle,
                rank: Int = 0,
                collisionRank: Int? = nil,
                minCameraZoom: Float = 0,
                maxCameraZoom: Float = .infinity,
                icon: PoiSpriteIcon? = nil,
                placement: LabelPlacement = .screen,
                standsOnRoof: Bool = false,
                isLocal: Bool = false) {
        self.key = key
        self.text = text
        self.rank = rank
        self.collisionRank = collisionRank ?? rank
        self.minCameraZoom = minCameraZoom
        self.maxCameraZoom = maxCameraZoom
        self.icon = icon
        self.placement = placement
        self.standsOnRoof = standsOnRoof
        self.isLocal = isLocal
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
                                zoomFade: ImmersiveMapZoomFade = .fadeIn(from: 0, to: 1),
                                sphereColor: SIMD3<Float>? = nil) -> FeatureStyle {
        .line(LineStyle(pass: LinePass.pointLocked(key: key,
                                                   color: color,
                                                   widthPoints: max(0, widthPoints),
                                                   dashLengthPoints: max(0, dashLengthPoints),
                                                   dashGapPoints: max(0, dashGapPoints),
                                                   zoomFade: zoomFade,
                                                   sphereColor: sphereColor),
                        fillsAreas: false))
    }

    /// A building: the footprint raised to the heights the schema reading
    /// states for it (`ImmersiveMapFeatureFacts.building`). `heightScale`,
    /// `anchorZoom` and `fallbackHeight` say how metres become tile units
    /// and what a building without a height gets, `edgeRadius` how round
    /// its edges are, in metres. A feature the reading found to be no
    /// building stays a flat fill.
    static func extrudedPolygon(key: UInt8,
                                color: SIMD4<Float>,
                                heightScale: Float = 1.0,
                                anchorZoom: Int = 16,
                                fallbackHeight: Float = 0,
                                edgeRadius: Float = 0) -> FeatureStyle {
        .extrusion(ExtrusionStyle(key: key,
                                  color: color,
                                  heightScale: heightScale,
                                  anchorZoom: anchorZoom,
                                  fallbackHeight: fallbackHeight,
                                  edgeRadius: edgeRadius))
    }

    /// A point label. The text is the name the schema reading states, in
    /// the map's language; this says how it is drawn, how important it is
    /// (`rank`, lower first, and `collisionRank`, which defaults to the
    /// rank), from which camera zoom, which sprite stands beside it,
    /// whether it stands on the screen or lies on the map, and whether it
    /// is local detail shown only near the camera.
    static func pointLabel(key: UInt8,
                           _ textStyle: LabelTextStyle,
                           rank: Int = 0,
                           collisionRank: Int? = nil,
                           minCameraZoom: Float = 0,
                           maxCameraZoom: Float = .infinity,
                           icon: PoiSpriteIcon? = nil,
                           placement: LabelPlacement = .screen,
                           standsOnRoof: Bool = false,
                           isLocal: Bool = false) -> FeatureStyle {
        .pointLabel(PointLabelStyle(key: key,
                                    text: Self.keyed(textStyle, key: key),
                                    rank: rank,
                                    collisionRank: collisionRank,
                                    minCameraZoom: minCameraZoom,
                                    maxCameraZoom: maxCameraZoom,
                                    icon: icon,
                                    placement: placement,
                                    standsOnRoof: standsOnRoof,
                                    isLocal: isLocal))
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
