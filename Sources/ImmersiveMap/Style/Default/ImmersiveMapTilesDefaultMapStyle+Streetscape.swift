// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The measured streetscape the second archive ships from z15: the
/// junction and carriageway surfaces, the parking lots, and the paint on
/// them (crossings, dividing and edge lines, the bus lane letter and the
/// stop sawtooth).
extension ImmersiveMapTilesDefaultMapStyle {
    /// Whether a feature is a pedestrian crossing, and whether it is painted.
    ///
    /// The tiles carry `crossing` on the footway that crosses the road, with
    /// `markings` naming the pattern where OSM says so. `marked` and
    /// `traffic_signals` are painted on the ground (a signalled crossing
    /// almost always is); `unmarked` is not, and `unknown` is the honest
    /// answer for a crossing nobody described, so neither gets a zebra.
    static func crossingMarking(props: [String: MvtValue]) -> Bool? {
        guard let crossing = props["crossing"]?.stringValue?.lowercased(), crossing.isEmpty == false else {
            return nil
        }
        if props["markings"]?.stringValue?.isEmpty == false {
            return true
        }
        switch crossing {
        case "marked", "traffic_signals", "zebra", "uncontrolled":
            return true
        default:
            return false
        }
    }

    /// From this tile zoom the street draws its full detail: crossings, the
    /// fine lane paint, the bus lane letter and the stop sawtooth, the
    /// parking bay comb.
    ///
    /// z15 is where the measured street starts: the road graph ships its
    /// junction and carriageway surfaces, its dividing and edge lines and its
    /// parking lots from that level, so everything painted ON that surface
    /// starts there too. A street therefore draws the same figures at z15 as
    /// at z16, and the tile level the engine swaps under a moving camera
    /// changes only the geometry's resolution, never which markings exist.
    /// How small a figure may get on screen is decided once, by the camera
    /// zoom band the paint fades in on (`LowZoomOverviewFade`
    /// `.roadMarkingStartZoom`), which is continuous in the camera rather
    /// than a step at a tile boundary.
    static let streetDetailMinimumTileZoom = 15

    /// A marked crossing: white stripes laid across the carriageway.
    ///
    /// The band is as deep as a crossing is on the ground and the stripes are
    /// derived from it, so the whole figure is a length rather than a screen
    /// pattern. It draws in the `detail` role, above every carriageway, and
    /// fades in on the markings' camera-zoom band with the rest of the paint.
    func crosswalkStyle(marked: Bool, tile: Tile) -> FeatureStyle {
        guard marked else {
            // An unmarked crossing is a place to cross, not a thing to draw:
            // the footway underneath it is already on the map.
            return hiddenStyle
        }
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        let bandUnits = Self.crosswalkBandMetres * unitsPerMetre
        return .road(RoadStyle(
            paint: [LinePass(key: Self.crosswalkKey,
                             color: Self.roadMarkingColor,
                             lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                             lineGeometry: LineGeometryStyle(lineWidth: bandUnits))],
            classPriority: Self.crosswalkClassPriority,
            decoration: .zebraCrossing()
        ))
    }

    /// How deep a crossing is along the road, in metres: the band the stripes
    /// fill. The stripe period is derived from it inside the builder, so the
    /// whole figure scales as one thing.
    static let crosswalkBandMetres: Double = 4.0
    static let crosswalkKey: UInt8 = 63

    /// A crossing sorts with the carriageway it is painted on, above every
    /// road fill: it is paint on the road, not a road.
    static let crosswalkClassPriority = 96

    /// Yellow road paint (a centre line that may not be crossed): muted in
    /// TONE like the white, and fully opaque like it (see roadMarkingColor).
    static let roadMarkingYellowColor = SIMD4<Float>(0.93, 0.83, 0.44, 1.0)

    /// A solid line of paint draws visibly thicker than a broken one: on the
    /// map a solid line is a statement (an edge, a line not to cross), and at
    /// the dash's hairline weight it read as just another dash row.
    static let solidMarkingWidthPoints: Float = 1.4

    /// A lane separator: one metre of paint, one and a half of gap (the
    /// source's own pattern for the line between two same-direction lanes).
    static let shippedSeparatorDashMetres: Double = 1.0
    static let shippedSeparatorGapMetres: Double = 1.5

    /// A dividing (centre) line: two metres of paint, four and a half of gap.
    static let shippedDividingDashMetres: Double = 2.0
    static let shippedDividingGapMetres: Double = 4.5

    /// A line of paint the source measured (`marking=...` in the road layer):
    /// the engine draws exactly the polyline the tiles ship, with the kind
    /// deciding stroke, colour and dash pattern. One `detail` pass, above
    /// every carriageway fill. The reading's `isShippedPaint` keeps the road
    /// machinery (surface clipping, junction insets, stitching) off it,
    /// because the line already ends exactly where the paint ends on the
    /// ground.
    func shippedMarkingStyle(_ paint: ImmersiveMapRoadPaint,
                             tile: Tile) -> FeatureStyle {
        switch paint.kind {
        case .crossing(marked: true):
            guard tile.z >= Self.streetDetailMinimumTileZoom else { return hiddenStyle }
            return crosswalkStyle(marked: true, tile: tile)
        case .busLane:
            // The lane's axis: the letter A stamped along it, feet toward
            // the driver, is what marks a dedicated lane on real asphalt.
            guard tile.z >= Self.streetDetailMinimumTileZoom else { return hiddenStyle }
            return busLaneLetterStyle()
        case .busStopKerb:
            // The stop's stretch of kerb: the yellow sawtooth of the bus
            // stop marking, folded from the shipped axis by the builder.
            guard tile.z >= Self.streetDetailMinimumTileZoom else { return hiddenStyle }
            return busStopZigzagStyle()
        case .crossing(marked: false):
            // A place to cross, not a thing to draw: same answer as for the
            // attribute-tagged unmarked crossings.
            return hiddenStyle
        case .edgeLine:
            // The roadway edge is already drawn: every carriageway wears the
            // grey kerb along its outline. A white solid painted a step
            // inside it doubled the road's edge into two parallel strokes,
            // so the shipped edge line stays data-only. The paint in the
            // middle (dividing lines, separators) keeps drawing.
            return hiddenStyle
        case .dividingLine, .laneSeparator:
            break
        case .other:
            // A kind this style does not know yet (a stop line, an arrow): a
            // newer tile against an older engine. Nothing is better than a
            // guess drawn wrong.
            return hiddenStyle
        }
        if tile.z < Self.streetDetailMinimumTileZoom {
            return hiddenStyle
        }
        // The paint colour: white unless the source says yellow, and yellow
        // only where it means something (a centre line): a key is a baked
        // style, so every (kind, colour) pair must map to its own.
        let isYellow = paint.isYellow && paint.kind != .laneSeparator
        let color = isYellow ? Self.roadMarkingYellowColor : Self.roadMarkingColor
        // Solid or dashed comes from the source where it says, with the
        // kind's own default behind it: a separator is dashed, a dividing
        // line dashed unless stated solid.
        let dashed = paint.isDashed ?? true
        // A key is a baked style, so every (kind, colour, solid-or-dashed)
        // triple carries its own: a solid line is wider than a dashed one,
        // and two features under one key must bake identically.
        let key: UInt8
        switch (paint.kind, isYellow, dashed) {
        case (.laneSeparator, _, true): key = 58
        case (.laneSeparator, _, false): key = 64
        case (.dividingLine, false, true): key = 60
        case (.dividingLine, true, true): key = 61
        case (.dividingLine, false, false): key = 65
        case (.dividingLine, true, false): key = 66
        // 59, 62, 67 and 68 were the edge-line keys; retired with the edge
        // lines themselves, not to be reused for anything else.
        default: key = 60
        }
        let dashMetres: Double
        let gapMetres: Double
        switch paint.kind {
        case .laneSeparator:
            dashMetres = Self.shippedSeparatorDashMetres
            gapMetres = Self.shippedSeparatorGapMetres
        default:
            dashMetres = Self.shippedDividingDashMetres
            gapMetres = Self.shippedDividingGapMetres
        }
        let widthPoints = dashed ? Self.roadMarkingWidthPoints : Self.solidMarkingWidthPoints
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        // Same construction as the synthesized lane paint: a point-locked
        // stroke on a tight ribbon, the dash period a length in metres
        // converted to this tile's units so the dashes sit still on the
        // asphalt. No end inset and no lateral offset: the polyline IS the
        // paint, measured where it lies.
        let ribbonUnits = Double(widthPoints) * Self.roadMarkingRibbonUnitsPerPoint
        let geometry = LineGeometryStyle(lineWidth: ribbonUnits,
                                                            lineCapRound: false,
                                                            lineJoinRound: true)
        let dashLength: Float = dashed ? Float(dashMetres * unitsPerMetre) : 0
        let dashGap: Float = dashed ? Float(gapMetres * unitsPerMetre) : 0
        let pass = LinePass(key: key,
                            color: color,
                            lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                            lineWidthPoints: widthPoints,
                            dashLengthPoints: dashLength,
                            dashGapPoints: dashGap,
                            dashInTileUnits: dashed,
                            lineGeometry: geometry)
        return .road(RoadStyle(paint: [pass], classPriority: Self.crosswalkClassPriority))
    }

    /// A junction area (`subclass=junction_area`): the carriageway of a junction
    /// as a polygon. Two passes in the automobile tier, like a road: the kerb
    /// on the outline (casing role, so every ribbon's fill and the area's own
    /// fill cover it where they overlap) and the surface (fill role). The
    /// surface takes the color of the class that enters it, so it merges into
    /// the ribbons of that class seamlessly; the kerb is the same fixed margin
    /// a ribbon wears. Below the separate-road zoom the area draws as a plain
    /// ground polygon in the road color.
    /// Only graph-reconstructed surfaces reach this style (the caller hides
    /// a hand-mapped `area:highway`, see the routing above), so
    /// `reconstructed` is always true today: a graph surface cuts the paint
    /// of the roads inside it, because the measured paint ships as its own
    /// lines. The parameter stays for the day hand-mapped areas return for
    /// regions without a reconstruction.
    func junctionAreaStyle(cls: String?,
                           tunnel: Bool,
                           tile: Tile,
                           reconstructed: Bool) -> FeatureStyle {
        let roads = theme.layers.roads
        let classColor: SIMD4<Float>
        let fillKey: UInt8
        let priority: Int
        switch cls {
        case "motorway": classColor = roads.motorway; fillKey = 56; priority = 95
        case "trunk": classColor = roads.trunk; fillKey = 54; priority = 90
        case "primary": classColor = roads.primary; fillKey = 52; priority = 80
        case "secondary": classColor = roads.secondary; fillKey = 50; priority = 78
        case "tertiary": classColor = roads.tertiary; fillKey = 48; priority = 74
        case "service": classColor = roads.service; fillKey = 42; priority = 46
        default: classColor = roads.minor; fillKey = 44; priority = 50
        }
        // A crossing wears exactly the class colour, not a tone of its own.
        // The reconstructed polygons overlap each other, the hand-mapped
        // areas and the ribbons, and overlaps of one colour are invisible
        // where a distinct tone showed every one as a diagonal seam.
        // A tunnel's surface is its roof seen from above: the class colour
        // at the tunnel opacity, and nothing drawn on it (the parser clips
        // the shipped paint out of it).
        let color = tunnel ? Self.tunnelTone(classColor) : classColor
        let surfaceKey = tunnel ? Self.roadTunnelKey(forFillKey: fillKey) : fillKey
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        let kerbWidth = 2 * Self.roadCasingMetresPerSide * unitsPerMetre
        var kerb: LinePass?
        if tunnel == false, theme.roadMetrics.drawsCasing {
            kerb = LinePass(key: Self.roadCasingKey(forFillKey: fillKey),
                            color: roadCasingColor(from: classColor),
                            lowZoomFadeMask: roadLowZoomFadeMask,
                            lineGeometry: LineGeometryStyle(lineWidth: kerbWidth, lineJoinRound: true))
        }
        return .road(RoadStyle(
            casing: kerb,
            fill: LinePass(key: surfaceKey,
                           color: color,
                           lowZoomFadeMask: roadLowZoomFadeMask,
                           lineGeometry: LineGeometryStyle(lineWidth: 100)),
            classPriority: priority,
            surfacePaint: tunnel ? .cutsAll : reconstructed ? .cutsSynthesized : .keeps
        ))
    }

    /// A surface parking lot (`subclass=parking_area`): service-tier asphalt
    /// with the same kerb a junction area wears, plus, from the zoom where
    /// paint reads, a `detail` pass that the parser fills with the
    /// synthesized parking-bay comb (`ParkingBayGeometryBuilder`). The comb
    /// is a stylization, not a claim about mapped spaces, which OSM almost
    /// never carries; the polygon and its `orientation` hint are the facts.
    /// The surface clips the ribbons inside it (a parking aisle needs no kerb
    /// of its own across the lot) and never cuts anyone's paint. A tile
    /// without the streetscape draws no lot at all (the routing hides it):
    /// the lot is a streetscape figure like everything else painted on
    /// asphalt.
    func parkingAreaStyle(tile: Tile) -> FeatureStyle {
        let roads = theme.layers.roads
        let fillKey: UInt8 = 42
        let color = roads.service
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        let kerbWidth = 2 * Self.roadCasingMetresPerSide * unitsPerMetre
        let kerb = LinePass(key: Self.roadCasingKey(forFillKey: fillKey),
                            color: roadCasingColor(from: color),
                            lowZoomFadeMask: roadLowZoomFadeMask,
                            lineGeometry: LineGeometryStyle(lineWidth: kerbWidth, lineJoinRound: true))
        let asphalt = LinePass(key: fillKey,
                               color: color,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               lineGeometry: LineGeometryStyle(lineWidth: 100))
        // The comb from the zoom the lot itself ships at, like every other
        // figure painted on a road surface: a lot looks the same at z15 as
        // at z16, and the camera-zoom band decides how faint the stripes are.
        var comb: [LinePass] = []
        if tile.z >= Self.streetDetailMinimumTileZoom {
            comb = [LinePass(key: Self.parkingBayKey,
                             color: Self.roadMarkingColor,
                             lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                             lineWidthPoints: Self.roadMarkingWidthPoints,
                             lineGeometry: LineGeometryStyle(
                                 lineWidth: Double(Self.roadMarkingWidthPoints) * Self.roadMarkingRibbonUnitsPerPoint
                             ))]
        }
        return .road(RoadStyle(casing: kerb,
                               fill: asphalt,
                               paint: comb,
                               classPriority: 45,
                               decoration: comb.isEmpty ? .none : .parkingBays()))
    }

    static let parkingBayKey: UInt8 = 69

    /// The letter A along a dedicated bus lane: a polygon decoration in the
    /// detail role, like the zebra, in the plain marking paint. The line the
    /// tiles ship is the lane's axis with the direction of travel baked in;
    /// the builder does the stamping, and the reading's `isShippedPaint`
    /// keeps the road machinery off the axis itself.
    func busLaneLetterStyle() -> FeatureStyle {
        return .road(RoadStyle(
            paint: [LinePass(key: Self.busLaneLetterKey,
                             color: Self.roadMarkingColor,
                             lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                             lineGeometry: LineGeometryStyle(lineWidth: 1))],
            classPriority: Self.crosswalkClassPriority,
            decoration: .busLaneLetter()
        ))
    }

    static let busLaneLetterKey: UInt8 = 71

    /// The yellow sawtooth at a public transport stop, same construction as
    /// the letter: a polygon decoration in the detail role, in the yellow
    /// road paint.
    func busStopZigzagStyle() -> FeatureStyle {
        return .road(RoadStyle(
            paint: [LinePass(key: Self.busStopZigzagKey,
                             color: Self.roadMarkingYellowColor,
                             lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                             lineGeometry: LineGeometryStyle(lineWidth: 1))],
            classPriority: Self.crosswalkClassPriority,
            decoration: .busStopZigzag()
        ))
    }

    static let busStopZigzagKey: UInt8 = 77
}
