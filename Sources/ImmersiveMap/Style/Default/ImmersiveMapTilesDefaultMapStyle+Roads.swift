// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The roads: the `transportation` layer's lines, from the overview
/// strokes of a country view to the symbols of a street, with the casing
/// and the fill of each. How wide a road is lives in the `RoadWidths`
/// extension, and the surfaces and paint the streetscape ships in
/// `Streetscape`.
extension ImmersiveMapTilesDefaultMapStyle {
    /// Markings fade on their own band (see `LowZoomOverviewFade`), so they
    /// carry the mask that selects it instead of the roads' one.
    static let roadMarkingLowZoomFadeMask: Float = 4.0

    func transportationStyle(cls: String?,
                             props: [String: MvtValue],
                             road: ImmersiveMapRoadFacts,
                             tile: Tile,
                             layerCarriesStreetscape: Bool = true,
                             layerShipsMeasuredCrossings: Bool = false) -> FeatureStyle {
        let tileZoom = tile.z
        let isTunnel = road.isTunnel
        let subclass = props["subclass"]?.stringValue?.lowercased()
        let roads = theme.layers.roads
        // Paint the source measured on the ground, shipped as its own line:
        // a lane line, the carriageway edge, a crossing. It carries no class
        // and no name, only what it is (`marking`) and what colour it is
        // painted (`paint`), and it bypasses every rule below, which are all
        // about roads.
        if let paint = road.paint {
            return shippedMarkingStyle(paint, tile: tile)
        }
        // A `<class>_construction` segment belongs to its base class: the
        // source ships it from the same zoom (a z4 tile carries motorway and
        // motorway_construction and nothing else), and hiding it cuts the
        // corridor mid-line. It gates and colors like the base class and
        // draws point-dashed, without casing or accent: a road that exists
        // as a corridor but is not finished.
        let constructionSuffix = "_construction"
        let isConstruction = cls?.hasSuffix(constructionSuffix) == true
        let effectiveClass = isConstruction
            ? cls.map { String($0.dropLast(constructionSuffix.count)) }
            : cls
        // A class draws only from the zoom where it can carry meaning: over a
        // country or regional view every road the tile ships is a sub-pixel
        // hairline, and drawing all of them just greys the map. Majors appear
        // first, the minor network fills in toward street level.
        guard tileZoom >= roadClassMinimumZoom(effectiveClass) else {
            return hiddenStyle
        }
        // A marked pedestrian crossing: the line the tiles ship across the
        // carriageway carries where it is, which way it faces and how long it
        // is, which is everything a zebra is made of. It draws as stripes on
        // the asphalt instead of as a footway ribbon.
        // Only in a tile with the streetscape: a zebra is paint on a
        // carriageway, and a street map's stroke has no carriageway to paint
        // on, so there the crossing is hidden and the footway underneath it
        // is the map. Not in a tunnel, where there is only the roof to see,
        // and not where the source measured the crossings itself: those are
        // the same crossings seen through OSM tags, and each is striped once.
        if let crossing = Self.crossingMarking(props: props), tileZoom >= Self.streetDetailMinimumTileZoom {
            guard layerCarriesStreetscape, isTunnel == false, layerShipsMeasuredCrossings == false else {
                return hiddenStyle
            }
            return crosswalkStyle(marked: crossing, tile: tile)
        }
        // Without the streetscape the roads are lines and nothing else: no
        // surface polygon, no parking lot. An asphalt polygon among the
        // symbol strokes reads as a hole in the map rather than as a road.
        if layerCarriesStreetscape == false {
            switch road.kind {
            case .surface, .parkingLot:
                return hiddenStyle
            case .centreline, .paint:
                break
            }
        }
        // A junction area: the carriageway as the tiles map it, a polygon.
        // It draws as the surface of the road class that enters it, with the
        // kerb on its outline, in the automobile tier; the ribbons that enter
        // it run under it, so their kerbs end at its edge and never cross it.
        // A carriageway area is the same thing for a road between junctions:
        // the street's surface computed from the road graph, one polygon per
        // carriageway, edge-consistent with the junction polygons it meets.
        switch road.kind {
        case .surface(let reconstructed):
            // Only the graph-reconstructed surfaces draw. A hand-mapped
            // area:highway often covers a whole street, including the gap
            // between the two one-way halves of a dual carriageway:
            // painted, it welded the two reconstructed bodies into one mass
            // with both inner edge lines stranded inside it. The roadway is
            // filled by the reconstruction alone; the tag still ships and
            // can be turned back on here if a region without reconstruction
            // needs it.
            guard reconstructed else {
                return hiddenStyle
            }
            return junctionAreaStyle(cls: effectiveClass,
                                     tunnel: isTunnel,
                                     tile: tile,
                                     reconstructed: true)
        case .parkingLot:
            // A surface parking lot: its own asphalt with a kerb, like a
            // junction area of the service tier, and from street zoom the
            // synthesized comb of parking-bay stripes on top.
            return parkingAreaStyle(tile: tile)
        case .centreline, .paint:
            break
        }
        // An older test build shipped bus lanes as toned polygons
        // (`bus_lane_area`); the lane is now the letter A stamped along its
        // axis (`marking=bus_lane`), and the polygon draws nothing.
        if subclass == "bus_lane_area" {
            return hiddenStyle
        }
        // Casing joins a class only from the zoom where the fill is wide
        // enough (about two points) for an edge to render; below that a
        // sub-pixel casing just muddies the fill's antialiasing.
        let casingZoom = tileZoom >= 12 && isConstruction == false
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
        // era's rules below, with its casing and its paint. See
        // `overviewRoadStroke` for the classes.
        if tileZoom <= Self.overviewRoadMaximumTileZoom,
           let stroke = Self.overviewRoadStroke(cls: effectiveClass, tileZoom: tileZoom) {
            return overviewRoadStyle(stroke,
                                     cls: effectiveClass,
                                     color: Self.streetRoadColor(cls: effectiveClass, roads: roads),
                                     fadeStartZoom: Self.overviewRoadFadeStartZoom(cls: effectiveClass),
                                     tileZoom: tileZoom,
                                     tunnel: isTunnel,
                                     construction: isConstruction)
        }
        // From here the road is the street era's symbol: the class's width
        // in points from the theme (`roadStyle`) and the casing the theme
        // asks for. The width never reads the lane count: a symbol is the
        // same on every street of its class, and nothing is painted on it
        // but what the streetscape measured.
        // The symbol's width: what the class draws at on screen up to the
        // theme's world lock zoom, and the ground width it had there past
        // it. Constant in points, so a street keeps one readable weight
        // across the region zooms instead of doubling with every tile
        // level. The theme states it (`RoadMetrics.symbolWidthPoints`).
        let symbolWidthPoints = theme.roadMetrics.symbolWidthPoints.value(forClass: effectiveClass)
        switch effectiveClass {
        case "motorway":
            return roadStyle(fillKey: 56, color: roads.motorway, priority: 95, casing: casingZoom, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass,
                             construction: isConstruction)
        case "trunk":
            return roadStyle(fillKey: 54, color: roads.trunk, priority: 90, casing: casingZoom, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass,
                             construction: isConstruction)
        case "primary":
            return roadStyle(fillKey: 52, color: roads.primary, priority: 80, casing: casingZoom, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass,
                             construction: isConstruction)
        case "secondary":
            return roadStyle(fillKey: 50, color: roads.secondary, priority: 78, casing: casingZoom, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass,
                             construction: isConstruction)
        case "tertiary":
            return roadStyle(fillKey: 48, color: roads.tertiary, priority: 74, casing: casingZoom, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass,
                             construction: isConstruction)
        case "minor":
            return roadStyle(fillKey: 44, color: roads.minor, priority: 50, casing: tileZoom >= 13, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass)
        case "service":
            // A parking aisle sits one step below
            // the rest of the tier: a parking lot owns its aisles (and eats
            // their ribbons), but must not eat the service roads that merely
            // pass along it, a bus lane mapped as its own way among them.
            let isParkingAisle = props["service"]?.stringValue == "parking_aisle"
            return roadStyle(fillKey: 42, color: roads.service, priority: isParkingAisle ? 45 : 46, casing: tileZoom >= 14, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass)
        case "path", "track":
            // Park alleys and walkways (footway/path/track): a plain strip of
            // the ground color, no kerb and no dashes. Over land it is the
            // ground itself (the footway network is not a second road
            // system), and over a park, a square or water it reads as a pale
            // route across the surface. A kerb on a ground-colored strip
            // turned every path into a grey band wider than its interior.
            return roadStyle(fillKey: 40, color: roads.path, priority: 35, casing: false, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass)
        case "rail", "transit":
            // Railways are skipped for now: not drawn at any zoom, on any
            // surface. `railStyle` stays for when they come back.
            return hiddenStyle
        case "ferry":
            // A ferry route is a symbolic line like a border: a thin dashed
            // stroke in the water's colour, stated in points and held there
            // at every zoom.
            return FeatureStyle.pointLockedLine(key: 41,
                                                color: theme.layers.water,
                                                widthPoints: Self.ferryWidthPoints,
                                                dashLengthPoints: Self.ferryDashPoints,
                                                dashGapPoints: Self.ferryGapPoints)
        default:
            return roadStyle(fillKey: 43, color: roads.minor, priority: 40, casing: tileZoom >= 13, tunnel: isTunnel,
                             symbolWidthPoints: symbolWidthPoints, roadClass: effectiveClass)
        }
    }

    /// The ferry route's stroke: a dashed line a little heavier than a
    /// regional border, in points.
    static let ferryWidthPoints: Float = 1.2
    static let ferryDashPoints: Float = 6.0
    static let ferryGapPoints: Float = 4.0

    /// The tile zoom a road class first draws at. Majors carry a country
    /// view; the minor network only means something near street level. The
    /// road classes read the theme (`RoadMetrics.minimumTileZoom`); the
    /// ferry and the rail classes are not roads and keep their own.
    func roadClassMinimumZoom(_ cls: String?) -> Int {
        switch cls {
        case "ferry":
            return 8
        case "rail", "transit":
            return 10
        default:
            return theme.roadMetrics.minimumTileZoom.value(forClass: cls)
        }
    }

    /// The style key of everything a tunnel draws, one per class fill key.
    /// A key is a colour slot per tile: the parser bakes the first style it
    /// meets under a key and every polygon with that key samples it. A
    /// translucent tunnel sharing its class key made the first tunnel in a
    /// tile the colour of every road of that class in it. A tunnel pass
    /// never derives a casing or marking key from its key (both are skipped
    /// for tunnels), so the `+1` marking rule does not reach these. From the
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

    /// The opacity of everything a vehicular tunnel draws: its ribbon at
    /// the zooms a road is a line, and its road surface where the tiles
    /// ship one. A tunnel is a plain fill with this alpha and nothing else,
    /// no kerb, no dash, no paint, so the ground shows through it in
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
    /// (`LowZoomOverviewFade.classFadeMask`): the tile zoom that first ships
    /// it readably, so the class comes in with the camera instead of popping
    /// with the tile. Trunks are gated with motorways at z5 but the source
    /// only ships them from z6, so their fade starts where they exist.
    static func overviewRoadFadeStartZoom(cls: String?) -> Int {
        switch cls {
        case "motorway": return 5
        case "trunk": return 6
        case "primary": return 7
        case "secondary": return 9
        default: return 10
        }
    }

    /// The class grey the road draws in at every zoom: the same asphalt as
    /// the street era, so no colour blends or steps on the way down.
    static func streetRoadColor(cls: String?,
                                roads: ImmersiveMapTilesTheme.RoadLayerStyles) -> SIMD4<Float> {
        switch cls {
        case "motorway": return roads.motorway
        case "trunk": return roads.trunk
        case "primary": return roads.primary
        case "secondary": return roads.secondary
        default: return roads.tertiary
        }
    }

    /// The classes the overview era draws, with the key and the priority of
    /// each: one asphalt grey, rank read as width alone, the principle the
    /// street era follows. How wide and how opaque the stroke is at a camera
    /// zoom is the theme's ramp (`roadWidthRamp`), the same one the street
    /// era states, so the handover between the eras at a tile level shows
    /// nothing on screen.
    static func overviewRoadStroke(cls: String?, tileZoom: Int) -> OverviewRoadStroke? {
        switch cls {
        case "motorway":
            return OverviewRoadStroke(fillKey: 56, priority: 95)
        case "trunk":
            return OverviewRoadStroke(fillKey: 54, priority: 90)
        case "primary":
            return OverviewRoadStroke(fillKey: 52, priority: 80)
        case "secondary":
            return OverviewRoadStroke(fillKey: 50, priority: 78)
        case "tertiary":
            return OverviewRoadStroke(fillKey: 48, priority: 74)
        default:
            return nil
        }
    }

    /// The ramp a road class's symbol comes in over, from the theme: the
    /// overview stroke and its veil up to the overview zoom, the full symbol
    /// from the symbol zoom.
    func roadWidthRamp(cls: String?, extraWidthPoints: Float = 0) -> LinePass.WidthRamp {
        let metrics = theme.roadMetrics
        return LinePass.WidthRamp(startWidthPoints: metrics.overviewWidthPoints.value(forClass: cls) + extraWidthPoints,
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

    /// A road over a country or region view: a symbolic stroke, drawn
    /// through the point-locked line factory the borders use (see
    /// `FeatureStyle.pointLockedLine`) but with round joins and caps, so a
    /// corridor the tiles ship in pieces reads as one continuous line.
    /// Tunnels are the same stroke at the tunnel opacity; construction
    /// segments read as point-dashed corridors.
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

    func overviewRoadStyle(_ stroke: OverviewRoadStroke,
                           cls: String?,
                           color: SIMD4<Float>,
                           fadeStartZoom: Int,
                           tileZoom: Int,
                           tunnel: Bool,
                           construction: Bool) -> FeatureStyle {
        let dashed = construction && tunnel == false
        let fillKey = tunnel ? Self.roadTunnelKey(forFillKey: stroke.fillKey) : stroke.fillKey
        // The stroke is the class's symbol under the theme's ramp: the veil
        // and the hairline width of a country view are the ramp's start.
        let widthPoints = theme.roadMetrics.symbolWidthPoints.value(forClass: cls)
        let ramp = roadWidthRamp(cls: cls)
        let fillColor = tunnel ? Self.tunnelTone(color) : color
        // A dashed stroke keeps butt ends: a round cap would lay a disc past
        // the last dash of a corridor.
        let geometry = LineGeometryStyle(
            lineWidth: Self.rampedRibbonWidth(ramp, widthPoints: widthPoints, tileZoom: tileZoom),
            lineCapRound: dashed == false,
            lineJoinRound: true
        )
        let fill = LinePass(
            key: fillKey,
            color: fillColor,
            // The class fades in over the zoom level after it first
            // ships, continuous with the camera, instead of popping with
            // the tile.
            lowZoomFadeMask: LowZoomOverviewFade.classFadeMask(startZoom: fadeStartZoom),
            lineWidthPoints: widthPoints,
            dashLengthPoints: dashed ? 4.0 : 0,
            dashGapPoints: dashed ? 2.5 : 0,
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
                   roadClass: String?,
                   construction: Bool = false) -> FeatureStyle {
        // The road is a symbol: the class states a width in points, the
        // shader extrudes the centreline to exactly that many points at
        // every vertex up to the theme's world lock zoom, and to the ground
        // width those points had there past it. The ribbon the parser sees
        // is the point-locked host, as for the overview strokes, and the
        // same ramp the overview era states brings the symbol in, so the
        // tile level where the eras hand over changes nothing on screen.
        let worldLockZoom = theme.roadMetrics.worldLockZoom
        let casingMarginPoints = 2 * Float(Self.roadCasingPointsPerSide)
        let fillRamp = roadWidthRamp(cls: roadClass)
        let casingRamp = roadWidthRamp(cls: roadClass, extraWidthPoints: casingMarginPoints)
        let fillRibbonWidth = Double(symbolWidthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint
        // A tunnel is the plain ribbon at the tunnel opacity: no dash, no
        // kerb (skipped below), and butt ends. Where the
        // tiles ship the tunnel's surface the centreline runs a few units
        // past it into the portal quad; the surface clips the ribbon and the
        // stub that survives is a rectangle under the quad, whereas a round
        // cap on the cut end bulged half a carriageway back over the
        // translucent surface as a darker semicircle. The construction
        // point-dash only applies to surface segments.
        let fillGeometry = tunnel
            ? LineGeometryStyle(lineWidth: fillRibbonWidth, lineCapRound: false, lineJoinRound: true)
            : makeRoadGeometry(width: fillRibbonWidth)
        let constructionDash: (length: Float, gap: Float)? = construction && tunnel == false
            ? (length: 5.0, gap: 2.5)
            : nil
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
                                  lowZoomFadeMask: LowZoomOverviewFade.classFadeMask(startZoom: Self.casingMinimumCameraZoom),
                                  lineWidthPoints: casingWidthPoints,
                                  pointWidthWorldLockZoom: worldLockZoom,
                                  pointWidthRamp: casingRamp,
                                  lineGeometry: makeRoadGeometry(width: casingWidth))
        }
        let fillPass = LinePass(key: fillPassKey,
                                color: fillColor,
                                lowZoomFadeMask: roadLowZoomFadeMask,
                                lineWidthPoints: symbolWidthPoints,
                                dashLengthPoints: constructionDash?.length ?? 0,
                                dashGapPoints: constructionDash?.gap ?? 0,
                                pointWidthWorldLockZoom: worldLockZoom,
                                pointWidthRamp: fillRamp,
                                lineGeometry: fillGeometry)
        return .road(RoadStyle(casing: casingPass,
                               fill: fillPass,
                               classPriority: priority))
    }

    /// The railway's stroke, when railways come back: a dashed symbol in
    /// points, like every road, held on screen at every zoom.
    static let railWidthPoints: Float = 1.5
    static let railDashPoints: Float = 6.0
    static let railGapPoints: Float = 6.0

    func railStyle(subclass: String?, tileZoom: Int) -> FeatureStyle {
        // Subway lines (railway=subway) run in tunnels under buildings/parks and
        // read as a confusing dashed line, so we hide them. Surface rail (rail,
        // tram, light_rail, monorail) stays dashed.
        if subclass == "subway" {
            return hiddenStyle
        }
        let ribbonWidth = Double(Self.railWidthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint
        return .road(RoadStyle(
            fill: LinePass(key: 46,
                           color: theme.layers.roads.rail,
                           lowZoomFadeMask: roadLowZoomFadeMask,
                           lineWidthPoints: Self.railWidthPoints,
                           dashLengthPoints: Self.railDashPoints,
                           dashGapPoints: Self.railGapPoints,
                           lineGeometry: LineGeometryStyle(lineWidth: ribbonWidth)),
            classPriority: 30
        ))
    }

    /// The paint of a measured line: an off-white that reads on the asphalt
    /// grey without glaring, and fully OPAQUE. Muting lives in the tone, not
    /// the alpha: a translucent marking washed out against the surface, and
    /// wherever two decoration quads of one colour overlapped (the strokes
    /// of the bus-lane letter, the joints of the stop sawtooth) the alpha
    /// composited twice and stamped a visibly denser patch.
    static let roadMarkingColor = SIMD4<Float>(0.97, 0.97, 0.96, 1.0)
    static let roadMarkingWidthPoints: Float = 0.9

    /// Tile units of marking ribbon per point of stroke. Markings live on
    /// z15+ tiles, where a unit is a few centimetres, so a much tighter
    /// provisioning than the overview lines' 32 still hosts the stroke on a
    /// dense display, and a tighter ribbon is a shorter corner wedge.
    static let roadMarkingRibbonUnitsPerPoint: Double = 8

    /// Road border = the fill colour darkened and made fully opaque - a border of
    /// the same hue but darker, never see-through, drawn under the lighter fill.
    /// The step is small and uniform across the channels, so an asphalt-grey
    /// fill keeps its neutral hue in the edge (a channel-biased step would
    /// tint the casing against the fill) and the edge defines the street
    /// without drawing a dark net over the city.
    func roadCasingColor(from fill: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(fill.x - 0.13, 0.0),
                     max(fill.y - 0.13, 0.0),
                     max(fill.z - 0.13, 0.0),
                     1.0)
    }
}
