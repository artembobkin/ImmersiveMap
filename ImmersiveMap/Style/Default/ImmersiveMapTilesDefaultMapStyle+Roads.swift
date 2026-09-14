// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The roads: the `transportation` layer's lines, from the overview
/// strokes of a country view to the measured carriageways of a street,
/// with the casing, the fill and the lane paint the style synthesizes on
/// them. How wide a road is lives in the `RoadWidths` extension, and the
/// surfaces and paint the streetscape ships in `Streetscape`.
extension ImmersiveMapTilesDefaultMapStyle {
    /// The automobile tier draws without a grey kerb: the roadway is held
    /// by its fill against the ground and by the paint on it, the way the
    /// lane-level modes of commercial engines draw carriageways. The kerb
    /// doubled every painted edge into two parallel strokes and outlined
    /// roads that on the ground shade straight into the pavement. Gates the
    /// casing pass of every drive-tier ribbon and of the reconstructed
    /// surfaces; parking lots keep their kerb (a lot boundary, not a road
    /// edge), tunnels and paths never had one. The switch stays for the day
    /// a palette wants the kerb back.
    static let drawsAutomobileKerb = false

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
        let roads = configuration.layers.roads
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
        guard tileZoom >= Self.roadClassMinimumZoom(effectiveClass) else {
            return hiddenStyle
        }
        // A marked pedestrian crossing: the line the tiles ship across the
        // carriageway carries where it is, which way it faces and how long it
        // is, which is everything a zebra is made of. It draws as stripes on
        // the asphalt instead of as a footway ribbon.
        // Not in a tunnel, where there is only the roof to see, and not
        // where the source measured the crossings itself: those are the
        // same crossings seen through OSM tags, and each is striped once.
        if let crossing = Self.crossingMarking(props: props), tileZoom >= Self.streetDetailMinimumTileZoom {
            guard isTunnel == false, layerShipsMeasuredCrossings == false else {
                return hiddenStyle
            }
            return crosswalkStyle(marked: crossing, tile: tile)
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
            return parkingAreaStyle(tile: tile, layerCarriesStreetscape: layerCarriesStreetscape)
        case .centreline, .paint:
            break
        }
        // An older test build shipped bus lanes as toned polygons
        // (`bus_lane_area`); the lane is now the letter A stamped along its
        // axis (`marking=bus_lane`), and the polygon draws nothing.
        if subclass == "bus_lane_area" {
            return hiddenStyle
        }
        // Road widths grow with zoom: hairlines at country/regional zooms, full
        // width at street level. Base widths below are the z14+ (full) values.
        // With every drive tier sharing one asphalt grey, width is the whole
        // hierarchy, so the ramp is spread wide: majors gain width over what
        // color used to say for them, minors give a little back.
        let s = roadWidthScale(tileZoom: tileZoom)

        // Casing joins a class only from the zoom where the fill is wide
        // enough (about two points) for an edge to render; below that a
        // sub-pixel casing just muddies the fill's antialiasing. The width
        // floors keep the majors readable strokes instead of hairlines at
        // region zooms, and the overview accent gives motorways and trunks a
        // deeper asphalt grey over a country view, released to the light
        // street palette by the same continuous camera-zoom blend the ground
        // uses.
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
        // overlaps of round geometry are invisible. The symbol era runs
        // through tile z11: the world width only starts to carry meaning
        // past z12, and until then a road drawn from the tile scale is a
        // uniform hairline that says nothing about its rank. See
        // `overviewRoadStroke` for the ladder.
        if tileZoom <= Self.overviewRoadMaximumTileZoom,
           let stroke = Self.overviewRoadStroke(cls: effectiveClass, tileZoom: tileZoom) {
            return overviewRoadStyle(stroke,
                                     color: Self.streetRoadColor(cls: effectiveClass, roads: roads),
                                     fadeStartZoom: Self.overviewRoadFadeStartZoom(cls: effectiveClass),
                                     tunnel: isTunnel,
                                     construction: isConstruction)
        }
        // From here the width is the road's real carriageway, in metres
        // converted to this tile's units: at street zoom a six-lane avenue is
        // drawn six lanes wide, and the point floors below carry the class
        // through the zooms where that width is sub-pixel. Markings ride the
        // same fact, so they only appear where the surface can hold them.
        //
        // That is the streetscape's road, drawn to carry the measured
        // surfaces and paint where the tile ships them. In a tile without
        // the streetscape the road is a street map's stroke instead: a
        // width the class alone decides, the same on every street of the
        // class whatever the tiles say about lanes, a casing a point wide,
        // nothing painted on it. See `streetStrokeWidthUnits`.
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        let drawsStrokes = layerCarriesStreetscape == false
        let widthMetres = drawsStrokes
            ? Self.streetStrokeWidthUnits(cls: effectiveClass, tile: tile)
            : roadWidthUnits(cls: effectiveClass, props: props, tile: tile)
        let kerbUnitsPerSide = drawsStrokes
            ? Self.streetStrokeCasingPointsPerSide * Self.streetStrokeUnitsPerPoint(tile: tile)
            : Self.roadCasingMetresPerSide * unitsPerMetre
        // A centre divider separates two directions of travel. A one-way
        // carriageway (one half of a dual carriageway, a one-way street) has
        // none; where the tiles carry `oneway` it decides, and a tile that
        // does not is taken as two-way.
        let isOneWay = (parseIntValue(props["oneway"]).map { $0 != 0 } ?? false)
            || props["oneway"]?.stringValue?.lowercased() == "yes"
        // Markings are painted from what the tiles state, never from what a
        // class suggests. `lanes` is the only marking evidence the schema
        // carries, so a road that does not carry it stays bare asphalt: a
        // default lane count is a guess about the ground, and paint invented
        // from a guess is wrong in a way an empty carriageway never is. The
        // classes below tertiary are bare whatever they carry, because a
        // residential street or a service alley has no painted centre line
        // to draw. Where the count is known: a two-way street gets a centre
        // divider, a one-way carriageway the lines between its lanes (there
        // is no centre to divide, but a four-lane one-way avenue is still
        // painted).
        let taggedLaneCount = parseIntValue(props["lanes"]).map { min(max($0, 1), 12) }
        // The tiles state where the lane count came from: `tagged` is what a
        // mapper put on the way, `assumed` is the profile's default for the
        // class, shipped so that every road has a width to draw. Width takes
        // either; paint takes only the mapped one. A source that ships no
        // such field only ships `lanes` where it was mapped, so a missing
        // field reads as mapped.
        let laneCountIsMapped = props["lanes_src"].map { $0.stringValue == "tagged" } ?? true
        // An unpaved road has no paint on it to draw. Anything the tiles do
        // not classify says nothing either way and is left painted.
        let isUnpaved = props["surface"]?.stringValue == "unpaved"
        let marked = isConstruction == false
            && drawsStrokes == false
            && tileZoom >= Self.roadMarkingsMinimumTileZoom
            && Self.roadClassCarriesMarkings(effectiveClass)
            && laneCountIsMapped
            && isUnpaved == false
        let markings: RoadMarkings
        if marked, let taggedLaneCount, taggedLaneCount >= 2 {
            if isOneWay {
                // Every lane on a one-way carriageway runs the same way, so
                // the boundary between two of them is fixed by the count
                // alone: no knowledge of where each lane leads is needed.
                markings = .laneLines(laneCount: taggedLaneCount)
            } else if taggedLaneCount.isMultiple(of: 2) {
                // A two-way street is painted down the middle, and the middle
                // is a real boundary only when the lanes divide evenly. The
                // tiles carry the total; which of them run each way is
                // `lanes:forward`/`lanes:backward`, mapped on a few per cent
                // of streets, so an odd total leaves the split unknown.
                markings = .centreDivider
            } else {
                // An odd total: the centre of the carriageway falls inside a
                // driving lane rather than between two, and a line drawn
                // there is half a lane from where the paint is. Bare asphalt
                // is the honest answer, and it costs about seven per cent of
                // the painted streets in a city centre.
                markings = .none
            }
        } else {
            markings = .none
        }
        // Symbol widths: what the class draws at on screen until the camera
        // is close enough for the true carriageway to take over
        // (LowZoomOverviewFade.roadSurfaceBlend, z14 to z16). Constant in
        // points, so a street keeps one readable weight across the region
        // zooms instead of doubling with every tile level.
        switch effectiveClass {
        case "motorway":
            return roadStyle(fillKey: 56, color: roads.motorway, width: widthMetres, priority: 95, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 2.2, maximumWidthPoints: 7.0, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes,
                             markings: markings, construction: isConstruction)
        case "trunk":
            return roadStyle(fillKey: 54, color: roads.trunk, width: widthMetres, priority: 90, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 2.0, maximumWidthPoints: 6.5, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes,
                             markings: markings, construction: isConstruction)
        case "primary":
            return roadStyle(fillKey: 52, color: roads.primary, width: widthMetres, priority: 80, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 1.6, maximumWidthPoints: 6.0, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes, markings: markings, construction: isConstruction)
        case "secondary":
            return roadStyle(fillKey: 50, color: roads.secondary, width: widthMetres, priority: 78, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 1.2, maximumWidthPoints: 5.0, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes, markings: markings, construction: isConstruction)
        case "tertiary":
            return roadStyle(fillKey: 48, color: roads.tertiary, width: widthMetres, priority: 74, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 1.0, maximumWidthPoints: 4.5, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes, markings: markings, construction: isConstruction)
        case "minor":
            return roadStyle(fillKey: 44, color: roads.minor, width: widthMetres, priority: 50, casing: tileZoom >= 13, tunnel: isTunnel,
                             minimumWidthPoints: 0.9, maximumWidthPoints: 4.0, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes, markings: markings)
        case "service":
            // A service road is one lane wide and has nothing to divide, so
            // it carries no markings. A parking aisle sits one step below
            // the rest of the tier: a parking lot owns its aisles (and eats
            // their ribbons), but must not eat the service roads that merely
            // pass along it, a bus lane mapped as its own way among them.
            let isParkingAisle = props["service"]?.stringValue == "parking_aisle"
            return roadStyle(fillKey: 42, color: roads.service, width: widthMetres, priority: isParkingAisle ? 45 : 46, casing: tileZoom >= 14, tunnel: isTunnel,
                             minimumWidthPoints: 0.7, maximumWidthPoints: 2.5, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes)
        case "path", "track":
            // Park alleys and walkways (footway/path/track): a plain strip of
            // the ground color, no kerb and no dashes. Over land it is the
            // ground itself (the footway network is not a second road
            // system), and over a park, a square or water it reads as a pale
            // route across the surface. A kerb on a ground-colored strip
            // turned every path into a grey band wider than its interior.
            return roadStyle(fillKey: 40, color: roads.path, width: widthMetres, priority: 35, casing: false, tunnel: isTunnel,
                             minimumWidthPoints: 0.5, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes)
        case "rail", "transit":
            return railStyle(subclass: subclass, tileZoom: tileZoom)
        case "ferry":
            return line(key: 41, color: configuration.layers.water, width: 4 * s, dashLength: 8, dashGap: 8)
        default:
            return roadStyle(fillKey: 43, color: roads.minor, width: widthMetres, priority: 40, casing: tileZoom >= 13, tunnel: isTunnel,
                             minimumWidthPoints: 0.9, unitsPerMetre: unitsPerMetre, kerbUnitsPerSide: kerbUnitsPerSide, strokes: drawsStrokes)
        }
    }

    /// The tile zoom a road class first draws at. Majors carry a country
    /// view; the minor network only means something near street level. The
    /// OpenMapTiles source ships most classes far earlier than they can read.
    static func roadClassMinimumZoom(_ cls: String?) -> Int {
        switch cls {
        case "motorway", "trunk":
            // The motorway skeleton starts at z5 by design choice, knowing
            // the source adds trunk-class geometry only from z6: a corridor
            // whose tagging changes to trunk shows cut until then.
            return 5
        case "primary":
            return 7
        case "ferry":
            return 8
        case "secondary":
            return 9
        case "tertiary", "rail", "transit":
            return 10
        case "service":
            return 13
        case "path", "track":
            return 14
        default:
            // minor and unknown classes.
            return 12
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

    /// The last tile zoom at which a road is a symbol: through it every
    /// drive tier that draws is a point-locked stroke (see
    /// `overviewRoadStroke`); from the next tile level the world width takes
    /// over with the point floors as a safety net.
    static let overviewRoadMaximumTileZoom = 11

    /// One class's stroke over a country or region view, in on-screen
    /// points, so the ladder is a design decision rather than a property of
    /// the tile scale.
    struct OverviewRoadStroke: Equatable {
        let fillKey: UInt8
        let priority: Int
        /// Visible width in layout points.
        let widthPoints: Float
        /// Opacity of the stroke; 1 is the opaque street asphalt.
        let opacity: Float
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
                                roads: ImmersiveMapTilesDefaultMapStyleConfiguration.RoadLayerStyles) -> SIMD4<Float> {
        switch cls {
        case "motorway": return roads.motorway
        case "trunk": return roads.trunk
        case "primary": return roads.primary
        case "secondary": return roads.secondary
        default: return roads.tertiary
        }
    }

    /// The overview ladder: one asphalt grey, rank read as width alone, the
    /// principle the street era already follows, drawn as a veil: the
    /// stroke is the street grey at a little over half opacity and a step
    /// narrower than a full symbol, so the network sits in the land rather
    /// than on it and the ground colours stay the picture. The widths grow
    /// in three steps (country, region, city view). Where two pieces of a
    /// corridor overlap (the inner side of a bend, the round cap of one
    /// piece over the next) the veil doubles, which is the price of a
    /// translucent stroke; the street era from z12 draws opaque.
    static func overviewRoadStroke(cls: String?, tileZoom: Int) -> OverviewRoadStroke? {
        let band: Int
        switch tileZoom {
        case ...6: band = 0
        case 7...9: band = 1
        default: band = 2
        }
        let veil: Float = 0.6
        switch cls {
        case "motorway":
            return OverviewRoadStroke(fillKey: 56, priority: 95, widthPoints: [1.3, 1.6, 2.2][band], opacity: veil)
        case "trunk":
            return OverviewRoadStroke(fillKey: 54, priority: 90, widthPoints: [1.1, 1.4, 1.9][band], opacity: veil)
        case "primary":
            return OverviewRoadStroke(fillKey: 52, priority: 80, widthPoints: [0.9, 1.0, 1.4][band], opacity: veil)
        case "secondary":
            return OverviewRoadStroke(fillKey: 50, priority: 78, widthPoints: [0.8, 0.8, 1.1][band], opacity: veil)
        case "tertiary":
            return OverviewRoadStroke(fillKey: 48, priority: 74, widthPoints: 0.9, opacity: veil)
        default:
            return nil
        }
    }

    /// A road over a country or region view: a symbolic stroke, drawn
    /// through the point-locked line factory the borders use (see
    /// `FeatureStyle.pointLockedLine`) but with round joins and caps, so a
    /// corridor the tiles ship in pieces reads as one continuous line.
    /// Tunnels are the same stroke at the tunnel opacity; construction
    /// segments read as point-dashed corridors.
    func overviewRoadStyle(_ stroke: OverviewRoadStroke,
                           color: SIMD4<Float>,
                           fadeStartZoom: Int,
                           tunnel: Bool,
                           construction: Bool) -> FeatureStyle {
        let dashed = construction && tunnel == false
        let fillKey = tunnel ? Self.roadTunnelKey(forFillKey: stroke.fillKey) : stroke.fillKey
        let veiled = SIMD4<Float>(color.x, color.y, color.z, color.w * stroke.opacity)
        let fillColor = tunnel ? Self.tunnelTone(veiled) : veiled
        // A dashed stroke keeps butt ends: a round cap would lay a disc past
        // the last dash of a corridor.
        let geometry = LineGeometryStyle(
            lineWidth: Double(stroke.widthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint,
            lineCapRound: dashed == false,
            lineJoinRound: true
        )
        return .road(RoadStyle(
            fill: LinePass(
                key: fillKey,
                color: fillColor,
                // The class fades in over the zoom level after it first
                // ships, continuous with the camera, instead of popping with
                // the tile.
                lowZoomFadeMask: LowZoomOverviewFade.classFadeMask(startZoom: fadeStartZoom),
                lineWidthPoints: stroke.widthPoints,
                dashLengthPoints: dashed ? 4.0 : 0,
                dashGapPoints: dashed ? 2.5 : 0,
                lineGeometry: geometry
            ),
            classPriority: stroke.priority
        ))
    }

    func roadStyle(fillKey: UInt8,
                   color: SIMD4<Float>,
                   width: Double,
                   priority: Int,
                   casing: Bool,
                   tunnel: Bool,
                   minimumWidthPoints: Float = 0,
                   maximumWidthPoints: Float = 0,
                   unitsPerMetre: Double = 0,
                   kerbUnitsPerSide: Double? = nil,
                   strokes: Bool = false,
                   markings: RoadMarkings = .none,
                   overviewAccent: SIMD4<Float>? = nil,
                   construction: Bool = false) -> FeatureStyle {
        // A tunnel is the plain ribbon at the tunnel opacity: no dash, no
        // kerb, no paint (both are skipped below), and butt ends. Where the
        // tiles ship the tunnel's surface the centreline runs a few units
        // past it into the portal quad; the surface clips the ribbon and the
        // stub that survives is a rectangle under the quad, whereas a round
        // cap on the cut end bulged half a carriageway back over the
        // translucent surface as a darker semicircle. The construction
        // point-dash only applies to surface segments.
        let fillGeometry = tunnel
            ? LineGeometryStyle(lineWidth: width, lineCapRound: false, lineJoinRound: true)
            : makeRoadGeometry(width: width)
        let constructionDash: (length: Float, gap: Float)? = construction && tunnel == false
            ? (length: 5.0, gap: 2.5)
            : nil
        // With an overview accent, the accent is the baked color and the
        // regular palette is its street counterpart: the continuous street
        // blend releases the accent exactly as it lightens the ground.
        let baseFillColor = overviewAccent ?? color
        let baseFillStreetColor = overviewAccent != nil ? color : nil
        let fillColor = tunnel ? Self.tunnelTone(baseFillColor) : baseFillColor
        let fillStreetColor = tunnel ? baseFillStreetColor.map(Self.tunnelTone) : baseFillStreetColor
        let fillPassKey = tunnel ? Self.roadTunnelKey(forFillKey: fillKey) : fillKey
        // The floor stops mattering once the world width exceeds it, so the
        // casing keeps its proportion by flooring half a point above the fill.
        let casingFloor = minimumWidthPoints > 0 ? minimumWidthPoints + 0.5 : 0

        // A stroke has no symbol ceiling: its world width IS the symbol,
        // chosen per class to read at street zoom, and it grows with the
        // camera past that the way a street map's roads do. The ceiling
        // exists for the carriageway, whose true width is far wider than a
        // readable symbol at region zooms.
        let maximumWidthPoints: Float = strokes ? 0 : maximumWidthPoints

        var casingPass: LinePass?
        if casing, tunnel == false, Self.drawsAutomobileKerb || strokes {
            // The casing is a kerb: a fixed margin of ground on each side of
            // the carriageway, not a fraction of it. As a fraction it was a
            // few units on a symbolic width and metres wide on a true one,
            // which turns every street into a dark-edged ribbon. A stroke's
            // casing is the same margin measured in points.
            let casingWidth = width + 2 * (kerbUnitsPerSide ?? Self.roadCasingMetresPerSide * unitsPerMetre)
            casingPass = LinePass(key: Self.roadCasingKey(forFillKey: fillKey),
                                  color: roadCasingColor(from: fillColor),
                                  streetColor: fillStreetColor.map(roadCasingColor(from:)),
                                  lowZoomFadeMask: roadLowZoomFadeMask,
                                  minimumWidthPoints: casingFloor,
                                  maximumWidthPoints: maximumWidthPoints > 0 ? maximumWidthPoints + 1.0 : 0,
                                  lineGeometry: makeRoadGeometry(width: casingWidth))
        }
        let fillPass = LinePass(key: fillPassKey,
                                color: fillColor,
                                streetColor: fillStreetColor,
                                lowZoomFadeMask: roadLowZoomFadeMask,
                                dashLengthPoints: constructionDash?.length ?? 0,
                                dashGapPoints: constructionDash?.gap ?? 0,
                                minimumWidthPoints: minimumWidthPoints,
                                maximumWidthPoints: maximumWidthPoints,
                                lineGeometry: fillGeometry)
        var paint: [LinePass] = []
        // Each marking is one dashed hairline pass, offset sideways from the
        // centreline. A one-way carriageway gets a line on every boundary
        // between its lanes; a two-way street gets the divider down the
        // middle and nothing else, because which of its lanes run each way is
        // not something the tiles know.
        var markingOffsets: [Double] = []
        if tunnel == false {
            switch markings {
            case .none:
                break
            case .centreDivider:
                markingOffsets = [0]
            case .laneLines(let laneCount):
                markingOffsets = Self.laneBoundaryOffsets(width: width, laneCount: laneCount)
            }
        }
        for markingOffset in markingOffsets {
            // The lane divider down an automobile road. It is paint on the
            // surface, so it is world-locked in both dimensions that matter:
            // the dash period is a length in metres (a city broken line,
            // three on and six off), converted to this tile's units, so the
            // dashes sit still on the asphalt and keep their count while the
            // camera zooms or the engine swaps the tile level serving the
            // road. Only the stroke width is point-locked, so a hairline of
            // paint stays a hairline instead of becoming a second road. It
            // draws in the `detail` role, above every fill.
            //
            // The ribbon is the narrowest that still hosts the point width:
            // the shader places the edge inside it, and the wider it is, the
            // longer the wedge the tessellator cuts out on the outside of
            // every corner where two segment rectangles meet. Round joins
            // fill that wedge with a fan carrying the join's own arc length,
            // so a dash spanning the corner paints it instead of notching.
            // Round caps are deliberately off: at a free end the dash pattern
            // must stop on the road, not lay a translucent disc past it.
            let markingRibbonUnits = Double(Self.roadMarkingWidthPoints) * Self.roadMarkingRibbonUnitsPerPoint
            // Paint stops half a carriageway short of the road's ends and of
            // every junction, as it does on the ground: the last dash never
            // pokes past the fill at a dead end, and the divider never runs
            // across the street it meets. A tile-seam cut is not an end and
            // keeps running flush into the neighbour (the parser tells them
            // apart).
            let markingEndInset = width * 0.5
            // Every stroke of a broken line is the same length. The line does
            // go solid before a junction on the ground, but drawn here it was
            // a twelve-metre stroke among three-metre ones, in the same
            // colour and the same width, separated from the last dash by
            // whatever the pattern left over: it read as paint of random
            // length rather than as an approach, and on a junction where
            // several carriageways fan in, as a thicket of them.
            paint.append(
                LinePass(key: Self.roadMarkingKey(forFillKey: fillKey),
                         color: Self.roadMarkingColor,
                         lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                         lineWidthPoints: Self.roadMarkingWidthPoints,
                         dashLengthPoints: Float(Self.roadMarkingDashMetres * unitsPerMetre),
                         dashGapPoints: Float(Self.roadMarkingGapMetres * unitsPerMetre),
                         dashInTileUnits: true,
                         lineGeometry: LineGeometryStyle(
                             lineWidth: markingRibbonUnits,
                             lineCapRound: false,
                             lineJoinRound: true,
                             endInset: markingEndInset,
                             lateralOffset: markingOffset
                         ))
            )
        }

        return .road(RoadStyle(casing: casingPass,
                               fill: fillPass,
                               paint: paint,
                               classPriority: priority))
    }

    func railStyle(subclass: String?, tileZoom: Int) -> FeatureStyle {
        // Subway lines (railway=subway) run in tunnels under buildings/parks and
        // read as a confusing dashed line, so we hide them. Surface rail (rail,
        // tram, light_rail, monorail) stays dashed.
        if subclass == "subway" {
            return hiddenStyle
        }
        let s = roadWidthScale(tileZoom: tileZoom)
        return .road(RoadStyle(
            fill: LinePass(key: 46,
                           color: configuration.layers.roads.rail,
                           lowZoomFadeMask: roadLowZoomFadeMask,
                           minimumWidthPoints: 0.7,
                           lineGeometry: makeDashedRoadGeometry(width: 4.0 * s, dashLength: 8, dashGap: 8)),
            classPriority: 30
        ))
    }

    /// From this tile zoom a drive-tier road is wide enough on screen to hold
    /// lane markings: below it the dashes would be noise inside a road only a
    /// few points across.
    static let roadMarkingsMinimumTileZoom = 13

    /// Whether a road class is painted at all.
    ///
    /// The through hierarchy is: an avenue carries a centre line and lane
    /// lines, and a map that leaves them out reads as unfinished. Everything
    /// below it does not: a residential street, a courtyard proezd, a service
    /// alley, a track and a footway have bare asphalt, and painting them
    /// covers the map in dashes that are not on the ground.
    static func roadClassCarriesMarkings(_ cls: String?) -> Bool {
        switch cls {
        case "motorway", "trunk", "primary", "secondary", "tertiary":
            return true
        default:
            return false
        }
    }

    /// The paint of a lane divider: an off-white that reads on the asphalt
    /// grey without glaring, and fully OPAQUE. Muting lives in the tone, not
    /// the alpha: a translucent marking washed out against the surface, and
    /// wherever two decoration quads of one colour overlapped (the strokes
    /// of the bus-lane letter, the joints of the stop sawtooth) the alpha
    /// composited twice and stamped a visibly denser patch.
    static let roadMarkingColor = SIMD4<Float>(0.97, 0.97, 0.96, 1.0)
    static let roadMarkingWidthPoints: Float = 0.9

    /// A city broken lane line: three metres of paint, six of gap.
    static let roadMarkingDashMetres: Double = 3.0
    static let roadMarkingGapMetres: Double = 6.0

    /// Tile units of marking ribbon per point of stroke. Markings live on
    /// z15+ tiles, where a unit is a few centimetres, so a much tighter
    /// provisioning than the overview lines' 32 still hosts the stroke on a
    /// dense display, and a tighter ribbon is a shorter corner wedge.
    static let roadMarkingRibbonUnitsPerPoint: Double = 8

    /// Markings sort one above their fill, out of the way of every other
    /// key the style uses. The `detail` pass role is what actually puts them
    /// over the carriageway; the key only has to stay unique.
    static func roadMarkingKey(forFillKey fillKey: UInt8) -> UInt8 {
        fillKey &+ 1
    }

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
