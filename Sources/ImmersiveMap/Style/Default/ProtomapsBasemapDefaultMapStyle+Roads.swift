// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The roads: the `roads` layer's lines, from the overview strokes of a
/// country view to the symbols of a street, with the casing and the fill
/// of each, the name laid along a street and the arrows of a one-way
/// street. How wide a road is: a road is a symbol, the theme states its
/// width on screen in points per class (`RoadMetrics.symbolWidthPoints`),
/// the shader draws exactly that many points until the world lock zoom and
/// the ground width those points had there from then on. Nothing here
/// reads a lane count or a width off the tiles.
extension ProtomapsBasemapDefaultMapStyle {
    typealias RoadClass = ProtomapsBasemapTheme.RoadClass

    /// The class a road of the basemap draws as, from its `kind` and
    /// `kind_detail`, nil for one the style does not draw: a sidewalk and a
    /// crossing (the z14 noise around every street), an aerialway, a pier.
    /// The ferries, the aeroways and the railways are handled before this
    /// is asked, since they are not roads of any class.
    static func roadClass(kind: String?, kindDetail: String?) -> RoadClass? {
        let detail = kindDetail.map { $0.hasSuffix("_link") ? String($0.dropLast(5)) : $0 }
        switch kind {
        case "highway":
            return .motorway
        case "major_road":
            switch detail {
            case "trunk": return .trunk
            case "primary": return .primary
            case "secondary": return .secondary
            default: return .tertiary
            }
        case "minor_road":
            return detail == "service" ? .service : .minor
        case "path":
            switch detail {
            case "sidewalk", "crossing": return nil
            default: return .path
            }
        case "other":
            return .other
        default:
            return nil
        }
    }

    func roadsStyle(kind: String?,
                    kindDetail: String?,
                    props: [String: MvtValue],
                    road: ImmersiveMapRoadFacts,
                    tileZoom: Int) -> FeatureStyle {
        let isTunnel = road.structure == .tunnel
        let roads = theme.layers.roads
        switch kind {
        case "ferry":
            // A ferry route is a symbolic line like a border: a thin dashed
            // stroke in the water's colour, stated in points and held there
            // at every zoom. It crosses the river under the bridges' decks.
            guard tileZoom >= Self.ferryMinimumTileZoom else { return hiddenStyle }
            return FeatureStyle.pointLockedLine(key: 23,
                                                color: theme.layers.water,
                                                widthPoints: Self.ferryWidthPoints,
                                                dashLengthPoints: Self.ferryDashPoints,
                                                dashGapPoints: Self.ferryGapPoints)
        case "aeroway":
            guard tileZoom >= Self.aerowayMinimumTileZoom else { return hiddenStyle }
            switch kindDetail {
            case "runway":
                return line(key: 28, color: theme.layers.aeroway, width: 8)
            case "taxiway":
                return line(key: 28, color: theme.layers.aeroway, width: 3)
            default:
                return hiddenStyle
            }
        case "rail":
            return railStyle(kindDetail: kindDetail, tileZoom: tileZoom)
        default:
            break
        }
        guard let roadClass = Self.roadClass(kind: kind, kindDetail: kindDetail) else {
            return hiddenStyle
        }
        // A class draws only from the zoom where it can carry meaning: over a
        // country or regional view every road the tile ships is a sub-pixel
        // hairline, and drawing all of them just greys the map. Majors appear
        // first, the minor network fills in toward street level.
        guard tileZoom >= theme.roadMetrics.minimumTileZoom.value(for: roadClass) else {
            return hiddenStyle
        }
        // Over a country or region view a road is a symbol, not a surface,
        // and it draws on the same principle as the country borders: one
        // point-locked stroke in the generic ground path, opaque from the
        // first frame it is visible. It is the same asphalt grey the street
        // era draws the class in, so the road never changes colour with the
        // zoom, and it has no kerb, because the street era has none either.
        // Joins and caps are round: the tiles chop a corridor into many short
        // features, and butt ends with plain joins tore the stroke open at
        // every bend and every feature boundary; on an opaque stroke the
        // overlaps of round geometry are invisible. The overview era runs
        // through tile z11; from z12 the same symbol draws by the street
        // era's rules below, with its casing, its name and its paint. See
        // `overviewRoadStroke` for the classes.
        if tileZoom <= Self.overviewRoadMaximumTileZoom,
           let stroke = Self.overviewRoadStroke(roadClass) {
            return overviewRoadStyle(stroke,
                                     roadClass: roadClass,
                                     color: Self.streetRoadColor(roadClass, roads: roads),
                                     fadeStartZoom: Self.overviewRoadFadeStartZoom(roadClass),
                                     tileZoom: tileZoom,
                                     tunnel: isTunnel)
        }
        // From here the road is the street era's symbol: the class's width
        // in points from the theme (`roadStyle`) and the casing the theme
        // asks for. The width never reads the lane count: a symbol is the
        // same on every street of its class. Constant in points, so a
        // street keeps one readable weight across the region zooms instead
        // of doubling with every tile level.
        let symbolWidthPoints = theme.roadMetrics.symbolWidthPoints.value(for: roadClass)
        // Casing joins a class only from the zoom where the fill is wide
        // enough (about two points) for an edge to render; below that a
        // sub-pixel casing just muddies the fill's antialiasing.
        let casingZoom = tileZoom >= 12
        var fillKey: UInt8
        var color: SIMD4<Float>
        var priority: Int
        var casing = casingZoom
        switch roadClass {
        case .motorway:
            (fillKey, color, priority) = (56, roads.motorway, 95)
        case .trunk:
            (fillKey, color, priority) = (54, roads.trunk, 90)
        case .primary:
            (fillKey, color, priority) = (52, roads.primary, 80)
        case .secondary:
            (fillKey, color, priority) = (50, roads.secondary, 78)
        case .tertiary:
            (fillKey, color, priority) = (48, roads.tertiary, 74)
        case .minor:
            (fillKey, color, priority) = (44, roads.minor, 50)
            casing = tileZoom >= 13
        case .service:
            // A parking aisle sits one step below the rest of the tier.
            let isParkingAisle = props["service"]?.stringValue == "parking_aisle"
            (fillKey, color, priority) = (42, roads.service, isParkingAisle ? 45 : 46)
            casing = tileZoom >= 14
        case .path:
            // Park alleys and walkways (footway/path/track): a plain strip of
            // the ground color, no kerb and no dashes. Over land it is the
            // ground itself (the footway network is not a second road
            // system), and over a park, a square or water it reads as a pale
            // route across the surface. A kerb on a ground-colored strip
            // turned every path into a grey band wider than its interior.
            (fillKey, color, priority) = (40, roads.path, 35)
            casing = false
        case .other:
            (fillKey, color, priority) = (43, roads.minor, 40)
            casing = tileZoom >= 13
        }
        // A ramp sorts one step under its parent at a junction, in the same
        // colour and width, so the junction reads as the parent's.
        if parseBoolValue(props["is_link"]) {
            priority -= 1
        }
        return roadStyle(fillKey: fillKey,
                         color: color,
                         priority: priority,
                         casing: casing,
                         tunnel: isTunnel,
                         symbolWidthPoints: symbolWidthPoints,
                         roadClass: roadClass,
                         name: road.name,
                         oneway: parseBoolValue(props["oneway"]),
                         tileZoom: tileZoom)
    }

    /// The ferry route's stroke: a dashed line a little heavier than a
    /// regional border, in points, from the tile zoom the basemap ships
    /// ferries readably.
    static let ferryMinimumTileZoom = 8
    static let ferryWidthPoints: Float = 1.2
    static let ferryDashPoints: Float = 6.0
    static let ferryGapPoints: Float = 4.0

    /// The runways and taxiways draw from the tile zoom the basemap ships
    /// them at.
    static let aerowayMinimumTileZoom = 10

    /// The tile zoom a road's name is laid along it from: the street era,
    /// where the symbol is wide enough to carry text.
    static let roadLabelMinimumTileZoom = 12

    /// The tile zoom the arrows of a one-way street appear from: the
    /// basemap states `oneway` from z14.
    static let onewayArrowMinimumTileZoom = 14

    /// The style key of everything a tunnel draws, one per class fill key.
    /// A key is a colour slot per tile: the parser bakes the first style it
    /// meets under a key and every polygon with that key samples it. A
    /// translucent tunnel sharing its class key made the first tunnel in a
    /// tile the colour of every road of that class in it. From the
    /// separate-road zoom keys do not order drawing (the road phases sort by
    /// structure, layer, role and class); below it the generic ground path
    /// draws by ascending key, where a motorway tunnel stroke sits above the
    /// other roads, invisible at a point and a half and twenty percent.
    static func roadTunnelKey(forFillKey fillKey: UInt8) -> UInt8 {
        switch fillKey {
        case 56: return 89
        case 54: return 88
        case 52: return 87
        case 50: return 86
        case 48: return 85
        case 44: return 84
        case 43: return 83
        case 42: return 82
        default: return 81
        }
    }

    /// Casing keys sort below every road fill (and above buildings at 30):
    /// below the separate-road zoom the generic ground path draws by
    /// ascending key, so this is what puts every casing under every fill,
    /// the same layering the separate-road phases produce at street zoom.
    static func roadCasingKey(forFillKey fillKey: UInt8) -> UInt8 {
        switch fillKey {
        case 56: return 39
        case 54: return 38
        case 52: return 37
        case 50: return 36
        case 48: return 35
        case 44: return 34
        case 43: return 33
        default: return 32
        }
    }

    /// The key of the paint on a class's asphalt, one per class fill key,
    /// above every fill key of the tier so the ground path never buries an
    /// arrow under the road that crosses it.
    static func roadMarkingKey(forFillKey fillKey: UInt8) -> UInt8 {
        switch fillKey {
        case 56: return 57
        case 54: return 55
        case 52: return 53
        case 50: return 51
        case 48: return 49
        case 44: return 45
        case 43: return 47
        case 42: return 58
        default: return 59
        }
    }

    /// The opacity of everything a vehicular tunnel draws: its ribbon at
    /// every zoom. A tunnel is a plain fill with this alpha and nothing
    /// else, no kerb, no dash, no paint, so the ground shows through it in
    /// whichever palette the map wears and the road network stays joined
    /// across it without pretending to be at grade. Eighty percent
    /// transparent: the tunnel is a hint of where the road goes, not a road.
    static let tunnelFillOpacity: Float = 0.2

    /// `color` with the tunnel opacity in place of its own alpha.
    static func tunnelTone(_ color: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(color.x, color.y, color.z, tunnelFillOpacity)
    }

    /// The last tile zoom of the overview era: through it a road is the bare
    /// overview stroke (see `overviewRoadStroke`); from the next tile level
    /// the same symbol draws by the street era's rules, with its casing and
    /// its paint.
    static let overviewRoadMaximumTileZoom = 11

    /// One class's stroke over a country or region view, in on-screen
    /// points, so the ladder is a design decision rather than a property of
    /// the tile scale.
    struct OverviewRoadStroke: Equatable {
        let fillKey: UInt8
        let priority: Int
    }

    /// The camera zoom a class fades in from, over the following zoom level
    /// (`classZoomFade`): the tile zoom that first ships it readably, so the
    /// class comes in with the camera instead of popping with the tile.
    /// Trunks are gated with motorways at z5 but the basemap only ships them
    /// from z6, so their fade starts where they exist.
    static func overviewRoadFadeStartZoom(_ roadClass: RoadClass) -> Int {
        switch roadClass {
        case .motorway: return 5
        case .trunk: return 6
        case .primary: return 7
        case .secondary: return 9
        default: return 10
        }
    }

    /// A fade in over the one zoom level from `startZoom`, what a road class
    /// and a road's casing come in with.
    static func classZoomFade(startZoom: Int) -> ImmersiveMapZoomFade {
        .fadeIn(from: Double(startZoom), to: Double(startZoom) + 1)
    }

    /// The class grey the road draws in at every zoom: the same asphalt as
    /// the street era, so no colour blends or steps on the way down.
    static func streetRoadColor(_ roadClass: RoadClass,
                                roads: ProtomapsBasemapTheme.RoadLayerStyles) -> SIMD4<Float> {
        switch roadClass {
        case .motorway: return roads.motorway
        case .trunk: return roads.trunk
        case .primary: return roads.primary
        case .secondary: return roads.secondary
        default: return roads.tertiary
        }
    }

    /// The classes the overview era draws, with the key and the priority of
    /// each: one asphalt grey, rank read as width alone, the principle the
    /// street era follows. How wide and how opaque the stroke is at a camera
    /// zoom is the theme's ramp (`roadWidthRamp`), the same one the street
    /// era states, so the handover between the eras at a tile level shows
    /// nothing on screen.
    static func overviewRoadStroke(_ roadClass: RoadClass) -> OverviewRoadStroke? {
        switch roadClass {
        case .motorway:
            return OverviewRoadStroke(fillKey: 56, priority: 95)
        case .trunk:
            return OverviewRoadStroke(fillKey: 54, priority: 90)
        case .primary:
            return OverviewRoadStroke(fillKey: 52, priority: 80)
        case .secondary:
            return OverviewRoadStroke(fillKey: 50, priority: 78)
        case .tertiary:
            return OverviewRoadStroke(fillKey: 48, priority: 74)
        default:
            return nil
        }
    }

    /// The ramp a road class's symbol comes in over, from the theme: the
    /// overview stroke and its veil up to the overview zoom, the full symbol
    /// from the symbol zoom.
    func roadWidthRamp(_ roadClass: RoadClass, extraWidthPoints: Float = 0) -> LinePass.WidthRamp {
        let metrics = theme.roadMetrics
        return LinePass.WidthRamp(startWidthPoints: metrics.overviewWidthPoints.value(for: roadClass) + extraWidthPoints,
                                  startZoom: metrics.overviewZoom,
                                  endZoom: metrics.symbolZoom,
                                  startAlpha: metrics.overviewOpacity)
    }

    /// The ribbon a pre-extruded tile bakes to host a ramped point width:
    /// the widest the stroke gets while the tile is the one on screen, which
    /// is at the end of its zoom level.
    static func rampedRibbonWidth(_ ramp: LinePass.WidthRamp, widthPoints: Float, tileZoom: Int) -> Double {
        Double(ramp.widthPoints(atZoom: Float(tileZoom + 1), endWidthPoints: widthPoints))
            * FeatureStyle.pointLockedRibbonUnitsPerPoint
    }

    /// From this tile zoom a road takes the engine's road path (stitched
    /// across features, sorted by structure and class, drawn over the whole
    /// ground) even while it is still a symbol stroke; below it the stroke
    /// is a plain ground line. z8 is where the engine used to switch on
    /// its own, kept so the picture does not change. The symbol era runs
    /// through z11, so this could move to z12 once that has been looked at.
    static let roadPathMinimumTileZoom = 8

    /// The camera zoom from which a road's casing shows: below it the fill
    /// is too narrow for an edge to read, and the kerb only muddies the
    /// antialiasing. The casing pass carries it as its fade band, so it
    /// eases in over the following zoom level, continuous with the camera.
    static let casingMinimumCameraZoom = 16

    /// The casing of a road's symbol, per side, in points: the same margin
    /// the theme's casing switch (`RoadMetrics.drawsCasing`) adds around the
    /// overview stroke, so the tile level where the eras hand over changes
    /// nothing on screen.
    static let roadCasingPointsPerSide: Double = 1

    func makeRoadGeometry(width: Double) -> LineGeometryStyle {
        LineGeometryStyle(lineWidth: width, lineCapRound: false, lineJoinRound: true)
    }

    /// A road over a country or region view: a symbolic stroke, drawn
    /// through the point-locked line factory the borders use (see
    /// `FeatureStyle.pointLockedLine`) but with round joins and caps, so a
    /// corridor the tiles ship in pieces reads as one continuous line.
    /// Tunnels are the same stroke at the tunnel opacity.
    func overviewRoadStyle(_ stroke: OverviewRoadStroke,
                           roadClass: RoadClass,
                           color: SIMD4<Float>,
                           fadeStartZoom: Int,
                           tileZoom: Int,
                           tunnel: Bool) -> FeatureStyle {
        let fillKey = tunnel ? Self.roadTunnelKey(forFillKey: stroke.fillKey) : stroke.fillKey
        // The stroke is the class's symbol under the theme's ramp: the veil
        // and the hairline width of a country view are the ramp's start.
        let widthPoints = theme.roadMetrics.symbolWidthPoints.value(for: roadClass)
        let ramp = roadWidthRamp(roadClass)
        let fillColor = tunnel ? Self.tunnelTone(color) : color
        let geometry = LineGeometryStyle(
            lineWidth: Self.rampedRibbonWidth(ramp, widthPoints: widthPoints, tileZoom: tileZoom),
            lineCapRound: true,
            lineJoinRound: true
        )
        let fill = LinePass(
            key: fillKey,
            color: fillColor,
            // The class fades in over the zoom level after it first
            // ships, continuous with the camera, instead of popping with
            // the tile.
            zoomFade: Self.classZoomFade(startZoom: fadeStartZoom),
            lineWidthPoints: widthPoints,
            pointWidthWorldLockZoom: theme.roadMetrics.worldLockZoom,
            pointWidthRamp: ramp,
            lineGeometry: geometry
        )
        // A ground line at the coarse zooms, a road from
        // `roadPathMinimumTileZoom`: the same stroke either way, and the
        // case is what tells the engine which path draws it.
        guard tileZoom >= Self.roadPathMinimumTileZoom else {
            return .line(LineStyle(pass: fill, fillsAreas: false))
        }
        return .road(RoadStyle(fill: fill, classPriority: stroke.priority))
    }

    func roadStyle(fillKey: UInt8,
                   color: SIMD4<Float>,
                   priority: Int,
                   casing: Bool,
                   tunnel: Bool,
                   symbolWidthPoints: Float,
                   roadClass: RoadClass,
                   name: String = "",
                   oneway: Bool = false,
                   tileZoom: Int = 16) -> FeatureStyle {
        // The road is a symbol: the class states a width in points, the
        // shader extrudes the centreline to exactly that many points at
        // every vertex up to the theme's world lock zoom, and to the ground
        // width those points had there past it. The ribbon the parser sees
        // is the point-locked host, as for the overview strokes, and the
        // same ramp the overview era states brings the symbol in, so the
        // tile level where the eras hand over changes nothing on screen.
        let worldLockZoom = theme.roadMetrics.worldLockZoom
        let casingMarginPoints = 2 * Float(Self.roadCasingPointsPerSide)
        let fillRamp = roadWidthRamp(roadClass)
        let casingRamp = roadWidthRamp(roadClass, extraWidthPoints: casingMarginPoints)
        let fillRibbonWidth = Double(symbolWidthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint
        // A tunnel is the plain ribbon at the tunnel opacity: no kerb
        // (skipped below), no paint, and butt ends.
        let fillGeometry = tunnel
            ? LineGeometryStyle(lineWidth: fillRibbonWidth, lineCapRound: false, lineJoinRound: true)
            : makeRoadGeometry(width: fillRibbonWidth)
        let fillColor = tunnel ? Self.tunnelTone(color) : color
        let fillPassKey = tunnel ? Self.roadTunnelKey(forFillKey: fillKey) : fillKey

        var casingPass: LinePass?
        // The casing is the theme's switch (`RoadMetrics.drawsCasing`): the
        // symbol's points plus a fixed margin of points on each side, under
        // the same lock and the same ramp as the fill, so the kerb keeps its
        // proportion at every zoom.
        if casing, tunnel == false, theme.roadMetrics.drawsCasing {
            let casingWidthPoints = symbolWidthPoints + casingMarginPoints
            let casingWidth = Double(casingWidthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint
            casingPass = LinePass(key: Self.roadCasingKey(forFillKey: fillKey),
                                  color: roadCasingColor(from: fillColor),
                                  zoomFade: Self.classZoomFade(startZoom: Self.casingMinimumCameraZoom),
                                  lineWidthPoints: casingWidthPoints,
                                  pointWidthWorldLockZoom: worldLockZoom,
                                  pointWidthRamp: casingRamp,
                                  lineGeometry: makeRoadGeometry(width: casingWidth))
        }
        let fillPass = LinePass(key: fillPassKey,
                                color: fillColor,
                                zoomFade: Self.roadZoomFade,
                                lineWidthPoints: symbolWidthPoints,
                                pointWidthWorldLockZoom: worldLockZoom,
                                pointWidthRamp: fillRamp,
                                lineGeometry: fillGeometry)
        // The name is laid along the street's own symbol: the basemap ships
        // it on the road line, with no label layer of its own.
        let label: LabelTextStyle? = name.isEmpty == false && tileZoom >= Self.roadLabelMinimumTileZoom
            ? labelTextStyle(key: Int(fillKey), appearance: theme.labels.road)
            : nil
        // The arrows of a one-way street: a paint stroke in the detail
        // role, above every fill of the tier, stamped with the arrow
        // figure along the surface segments. A tunnel carries no paint.
        var paint: [LinePass] = []
        var decoration: RoadDecorationKind = .none
        if oneway, tunnel == false, tileZoom >= Self.onewayArrowMinimumTileZoom {
            paint = [LinePass(key: Self.roadMarkingKey(forFillKey: fillKey),
                              color: theme.layers.roads.marking,
                              zoomFade: Self.roadMarkingZoomFade,
                              lineGeometry: LineGeometryStyle(lineWidth: Self.roadMarkingRibbonWidth))]
            decoration = .onewayArrow()
        }
        return .road(RoadStyle(casing: casingPass,
                               fill: fillPass,
                               paint: paint,
                               classPriority: priority,
                               decoration: decoration,
                               label: label))
    }

    /// The paint on the asphalt comes in over camera zoom 15 to 15.4:
    /// nothing below 15, where a figure a few metres long is noise rather
    /// than paint, and in full a little past it. The band starts at the
    /// theme's default world lock, so the paint arrives on a road that is
    /// already a width on the ground.
    static let roadMarkingZoomFade = ImmersiveMapZoomFade.fadeIn(from: 15, to: 15.4)

    /// The stroke the arrow figure is sized from, in tile units: the
    /// figure's length and width follow it (`RoadDirectionArrowGeometryBuilder`),
    /// and on the z14 and z15 tiles that carry the arrows a unit is a few
    /// decimetres, so a narrow stroke keeps the figure a few metres long.
    static let roadMarkingRibbonWidth: Double = 8

    /// The railway's stroke: a dashed symbol in points, like every road,
    /// held on screen at every zoom.
    static let railWidthPoints: Float = 1.5
    static let railDashPoints: Float = 6.0
    static let railGapPoints: Float = 6.0

    func railStyle(kindDetail: String?, tileZoom: Int) -> FeatureStyle {
        // Subway lines run in tunnels under buildings and parks and read as
        // a confusing dashed line, so they stay hidden. Surface rail (rail,
        // tram, light_rail, monorail) draws dashed.
        if kindDetail == "subway" {
            return hiddenStyle
        }
        let ribbonWidth = Double(Self.railWidthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint
        return .road(RoadStyle(
            fill: LinePass(key: 46,
                           color: theme.layers.roads.rail,
                           zoomFade: Self.roadZoomFade,
                           lineWidthPoints: Self.railWidthPoints,
                           dashLengthPoints: Self.railDashPoints,
                           dashGapPoints: Self.railGapPoints,
                           lineGeometry: LineGeometryStyle(lineWidth: ribbonWidth)),
            classPriority: 30
        ))
    }

    /// Road border = the fill colour darkened and made fully opaque, a border
    /// of the same hue but darker, never see-through, drawn under the lighter
    /// fill. The step is small and uniform across the channels, so an
    /// asphalt-grey fill keeps its neutral hue in the edge (a channel-biased
    /// step would tint the casing against the fill) and the edge defines the
    /// street without drawing a dark net over the city.
    func roadCasingColor(from fill: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(fill.x - 0.13, 0.0),
                     max(fill.y - 0.13, 0.0),
                     max(fill.z - 0.13, 0.0),
                     1.0)
    }
}
