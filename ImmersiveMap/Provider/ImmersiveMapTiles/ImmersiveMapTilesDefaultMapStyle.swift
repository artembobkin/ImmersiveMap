// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Default style for the OpenMapTiles-schema first-party provider, reading the
/// OpenMapTiles layer and field contract
/// (`class`/`subclass`/`brunnel`/`admin_level`/`rank`/`capital`).
final class ImmersiveMapTilesDefaultMapStyle: ImmersiveMapStyle {
    private static let implementationRevision: UInt32 = 74

    /// The automobile tier draws without a grey kerb: the roadway is held
    /// by its fill against the ground and by the paint on it, the way the
    /// lane-level modes of commercial engines draw carriageways. The kerb
    /// doubled every painted edge into two parallel strokes and outlined
    /// roads that on the ground shade straight into the pavement. Gates the
    /// casing pass of every drive-tier ribbon and of the reconstructed
    /// surfaces; parking lots keep their kerb (a lot boundary, not a road
    /// edge), tunnels and paths never had one. The switch stays for the day
    /// a palette wants the kerb back.
    private static let drawsAutomobileKerb = false

    private let fallbackKey: UInt8 = 0
    /// Roads opt into the engine's z3->4 camera-zoom fade band, so the major
    /// classes ease in over the globe instead of popping with the z4 tiles.
    private let roadLowZoomFadeMask: Float = 2.0
    /// Markings fade on their own band (see `LowZoomOverviewFade`), so they
    /// carry the mask that selects it instead of the roads' one.
    private static let roadMarkingLowZoomFadeMask: Float = 4.0
    private let landuseMinimumZoom = 6
    private let massiveOverviewMaximumZoom = 2
    private let globalLandcoverMaximumZoom = 9
    private let poiSpriteResolver = PoiSpriteResolver()
    private let configuration: ImmersiveMapTilesDefaultMapStyleConfiguration
    private let settings: ImmersiveMapSettings.StyleSettings
    private let mapBaseColors: ImmersiveMapBaseColors
    private let fallbackStyle: FeatureStyle

    init(configuration: ImmersiveMapTilesDefaultMapStyleConfiguration = .immersiveMapTilesDefault,
         settings: ImmersiveMapSettings.StyleSettings = ImmersiveMapSettings.default.style) {
        self.configuration = configuration
        self.settings = settings
        self.mapBaseColors = ImmersiveMapBaseColors(settings: settings.baseColors)
        self.fallbackStyle = FeatureStyle(
            key: fallbackKey,
            color: settings.fallbackFeatureColor,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    var preparedTileStyleRevision: UInt32 {
        settings.preparedTileStyleRevision &+ configuration.cacheFingerprint &+ Self.implementationRevision
    }

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        mapBaseColors
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let layer = data.layerName.lowercased()
        let props = data.properties
        let z = data.tile.z
        let cls = props["class"]?.stringValue?.lowercased()
        let subclass = props["subclass"]?.stringValue?.lowercased()

        switch layer {
        case "background":
            // Synthetic full-tile base quad the engine emits per tile. OpenMapTiles
            // has no land polygon, so this is what paints the land; without it the
            // base falls through to the red debug fallback. The street color
            // rides along in every tile: the shader lerps to it continuously
            // in camera zoom, so no tile-zoom boundary flips the ground.
            let overviewColor = z <= massiveOverviewMaximumZoom
                ? configuration.globalLandcover.grass
                : configuration.globalLandcover.land
            return polygon(key: 1,
                           color: overviewColor,
                           streetColor: configuration.layers.land)
        case "water":
            // Same pair for water: the saturated globe blue eases into the
            // pale street blue with the camera, identically in every tile.
            return polygon(key: 20,
                           color: configuration.globalLandcover.water,
                           streetColor: configuration.layers.water)
        case "waterway":
            return waterwayStyle(cls: cls, props: props)
        case "landcover":
            return landcoverStyle(cls: cls, subclass: subclass, tileZoom: z)
        case "globallandcover":
            return globalLandcoverStyle(cls: cls, tileZoom: z)
        case "landuse":
            return landuseStyle(cls: cls, tileZoom: z)
        case "park":
            return parkLayerStyle(cls: cls, subclass: subclass)
        case "building":
            return buildingStyle(tileZoom: z)
        case "aeroway":
            return line(key: 28, color: configuration.layers.aeroway, width: 4)
        case "transportation":
            return transportationStyle(cls: cls, props: props, tile: data.tile)
        case "boundary":
            return boundaryStyle(props: props, tileZoom: z)
        case "transportation_name":
            return roadLabelStyle(cls: cls)
        case "place":
            return placeLabelStyle(props: props)
        case "water_name":
            return waterLabelStyle(props: props)
        case "poi":
            return poiLabelStyle(props: props, tileZoom: z)
        case "mountain_peak":
            return pointLabel(key: 74, appearance: configuration.labels.poi)
        case "aerodrome_label":
            return pointLabel(key: 75, appearance: configuration.labels.poi)
        case "housenumber":
            return pointLabel(key: 76, appearance: houseNumberAppearance())
        default:
            return fallbackStyle
        }
    }

    // MARK: - Polygons

    private func landcoverStyle(cls: String?, subclass: String?, tileZoom: Int) -> FeatureStyle {
        // The continuous ESA `globallandcover` overlay covers z<=9 (the tile service's
        // overlay-maxzoom). Use it there and suppress the sparser OSM `landcover`,
        // which generalises into tile-filling polygons clipped at tile edges (abrupt
        // per-tile colour jumps). OSM landcover takes over from z10 (street detail).
        //
        // Polygon draw order is by ascending key. Beige landuse
        // (residential/industrial) is lowered to key 9 while all greenery goes
        // above it (11-18), otherwise a park lying inside a residential/block
        // polygon (leisure=park arrives as landcover grass/park) would be
        // covered by beige and look like bare ground. Greenery stays below
        // water (key 20) and roads.
        guard tileZoom >= 10 else {
            return hiddenStyle
        }
        // Each landcover color gets its own key (otherwise the first-wins
        // `styles[key]` collapses all landcover in a tile into the first
        // polygon's color, producing seams at tile borders). All of them sit
        // above the beige landuse (key 9) and below water (20).
        switch cls {
        case "wood", "forest":
            // The overview color is the WorldCover forest these polygons
            // replace at the handover, so they arrive wearing the color the
            // biomes converge on and finish the lerp to the street wood.
            return polygon(key: 11,
                           color: configuration.globalLandcover.forest,
                           streetColor: configuration.layers.wood)
        case "grass":
            // OSM tags countless small courtyards/verges as generic grass; at city
            // zooms suppress those (keep only real green-space subclasses) so they
            // don't tint the whole city.
            if tileZoom >= 13, isGenericGrassSubclass(subclass) {
                return hiddenStyle
            }
            return polygon(key: 12,
                           color: configuration.globalLandcover.grass,
                           streetColor: configuration.layers.grass)
        case "farmland":
            return polygon(key: 13,
                           color: configuration.globalLandcover.crop,
                           streetColor: configuration.layers.farmland)
        case "wetland":
            return polygon(key: 14,
                           color: configuration.globalLandcover.wetland,
                           streetColor: configuration.layers.wetland)
        case "ice":
            return polygon(key: 17,
                           color: configuration.globalLandcover.snow,
                           streetColor: configuration.layers.ice)
        case "sand":
            return polygon(key: 18,
                           color: configuration.globalLandcover.barren,
                           streetColor: configuration.layers.sand)
        case "rock":
            // Bare rock = ground color; no separate polygon over the base needed.
            return hiddenStyle
        default:
            // Unknown landcover: blend into the land base rather than paint it green.
            return hiddenStyle
        }
    }

    /// True for generic "grass" that is just urban verge/courtyard clutter (as
    /// opposed to a real park/garden/recreation area worth keeping green).
    private func isGenericGrassSubclass(_ subclass: String?) -> Bool {
        switch subclass {
        case "park", "garden", "recreation_ground", "golf_course", "cemetery",
             "meadow", "grassland", "nature_reserve", "dog_park", "pitch", "playground":
            return false
        default:
            return true
        }
    }

    /// ESA WorldCover-derived low-zoom landcover (layer `globallandcover`, merged
    /// into low-zoom tiles by the tile service). The dedicated soft-biome palette
    /// compresses contrast between neighbouring classes while keeping broad forests,
    /// grasslands, crops, wetlands and deserts legible at globe scale. At z0...2 the
    /// vegetation classes collapse into one large mass, with forests only subtly
    /// darker, so source polygon spikes do not dominate the globe. Per-class hole-free
    /// polygons are drawn in a fixed paint order: base land -> biomes -> snow on top.
    /// Keys stay below `water` (20) so oceans/lakes cover landcover.
    private func globalLandcoverStyle(cls: String?, tileZoom: Int) -> FeatureStyle {
        let colors = configuration.globalLandcover
        let vegetationBase = colors.grass
        // The WorldCover polygons are raster-derived blobs; at overview zooms
        // full-contrast categorical fills read as blotches, so the vegetation
        // classes blend toward one shared tone, fully merged over the globe
        // and releasing gradually to the unmixed palette by z9. Forests keep
        // a quarter of their distance so the big woodlands stay legible, the
        // same proportion the full merge always used. Barren and snow are
        // real geographic edges (deserts, ice caps) and stay unblended.
        let amount = Self.vegetationBlendAmount(tileZoom: tileZoom)
        // Each biome's street color is its OSM street-palette equivalent, so
        // through the handover a WorldCover forest converges on exactly the
        // color the OSM wood polygons that replace it will wear: only the
        // geometry source changes at the swap, never the color language.
        let layers = configuration.layers
        switch cls {
        case "land":
            return polygon(key: 2,
                           color: blend(colors.land, toward: vegetationBase, amount: amount),
                           streetColor: layers.land)
        case "barren":
            return polygon(key: 3, color: colors.barren, streetColor: layers.sand)
        case "grass", "shrub", "moss":
            return polygon(key: 4, color: colors.grass, streetColor: layers.grass)
        case "crop":
            return polygon(key: 5,
                           color: blend(colors.crop, toward: vegetationBase, amount: amount),
                           streetColor: layers.farmland)
        case "forest":
            return polygon(key: 6,
                           color: blend(colors.forest, toward: vegetationBase, amount: amount * 0.75),
                           streetColor: layers.wood)
        case "wetland", "mangroves":
            return polygon(key: 7,
                           color: blend(colors.wetland, toward: vegetationBase, amount: amount),
                           streetColor: layers.wetland)
        case "snow":
            return polygon(key: 8, color: colors.snow, streetColor: layers.ice)
        case "urban":
            // Cities are the one thing a region view exists to show: a soft
            // warm gray, clearly apart from the greens, handing over to the
            // OSM residential beige that replaces it from z10.
            return polygon(key: 10,
                           color: SIMD4<Float>(0.886, 0.871, 0.847, 1.0),
                           streetColor: layers.residential)
        default:
            // water: left to the background and water layers.
            return hiddenStyle
        }
    }

    /// How far the vegetation classes blend toward the shared tone at a tile
    /// zoom: 1 is the full massive-overview merge, 0 the unmixed palette.
    private static func vegetationBlendAmount(tileZoom: Int) -> Float {
        // The full merge exists for the globe (z0-2), where raster blobs must
        // disappear into one green mass. It releases fast below that: a half
        // blend held into the country zooms kept every class the same green
        // family while leaving the blob edges visible, which read as
        // camouflage blotches over a plain that is two-thirds cropland. By z5
        // the ground and the fields are back to their own near-cream tones and
        // forests are the one green left on them.
        switch tileZoom {
        case ...2: return 1.0
        case 3: return 0.5
        case 4: return 0.3
        case 5: return 0.15
        case 6: return 0.08
        case 7: return 0.04
        default: return 0.0
        }
    }

    private func blend(_ base: SIMD4<Float>,
                       toward target: SIMD4<Float>,
                       amount: Float) -> SIMD4<Float> {
        base + (target - base) * amount
    }

    private func landuseStyle(cls: String?, tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= landuseMinimumZoom else {
            return hiddenStyle
        }
        switch cls {
        case "residential", "suburb", "neighbourhood", "quarter", "allotments":
            // Beige residential/block fills go to the very bottom (key 9), below
            // greenery, otherwise they cover parks (landcover) inside residential polygons.
            return polygon(key: 9, color: configuration.layers.residential)
        case "industrial", "commercial", "retail", "railway", "quarry":
            return polygon(key: 9, color: configuration.layers.industrial)
        case "cemetery", "grass", "park", "recreation_ground", "garden":
            // One green color for all urban greenery (matches landcover grass)
            // to avoid a two-tone seam where the layers meet.
            return polygon(key: 15, color: configuration.layers.grass)
        default:
            // Unknown landuse: blend into the land base instead of the red fallback.
            return hiddenStyle
        }
    }

    // MARK: - Lines

    private func waterwayStyle(cls: String?, props: [String: MvtValue]) -> FeatureStyle {
        // Underground/culverted waterways (brunnel=tunnel, e.g. the Neglinnaya
        // under the Alexander Garden) are invisible in reality, so we hide them.
        if props["brunnel"]?.stringValue?.lowercased() == "tunnel" {
            return hiddenStyle
        }
        // The source ships major rivers from z3; without a floor their
        // 2.5-unit width is sub-pixel over a country view and the
        // antialiasing correctly dims them to near-invisibility, so a point
        // floor keeps them readable threads from the first tile they appear
        // in. World growth takes over at street zoom as with roads.
        let width: Double
        let minimumWidthPoints: Float
        switch cls {
        case "river", "canal":
            width = 2.5
            minimumWidthPoints = 0.7
        case "stream":
            width = 1.4
            minimumWidthPoints = 0.5
        default:
            width = 1.0
            minimumWidthPoints = 0.5
        }
        return line(key: 22,
                    color: configuration.layers.water,
                    width: width,
                    minimumWidthPoints: minimumWidthPoints)
    }

    private func transportationStyle(cls: String?,
                                     props: [String: MvtValue],
                                     tile: Tile) -> FeatureStyle {
        let tileZoom = tile.z
        let brunnel = props["brunnel"]?.stringValue?.lowercased()
        let isTunnel = brunnel == "tunnel"
        let subclass = props["subclass"]?.stringValue?.lowercased()
        let roads = configuration.layers.roads
        // Paint the source measured on the ground, shipped as its own line:
        // a lane line, the carriageway edge, a crossing. It carries no class
        // and no name, only what it is (`marking`) and what colour it is
        // painted (`paint`), and it bypasses every rule below, which are all
        // about roads.
        if let marking = props["marking"]?.stringValue?.lowercased(), marking.isEmpty == false {
            return shippedMarkingStyle(kind: marking, props: props, tile: tile)
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
        if let crossing = Self.crossingMarking(props: props), tileZoom >= Self.streetDetailMinimumTileZoom {
            return crosswalkStyle(marked: crossing, tile: tile)
        }
        // A junction area: the carriageway as the tiles map it, a polygon.
        // It draws as the surface of the road class that enters it, with the
        // kerb on its outline, in the automobile tier; the ribbons that enter
        // it run under it, so their kerbs end at its edge and never cross it.
        // A carriageway area is the same thing for a road between junctions:
        // the street's surface computed from the road graph, one polygon per
        // carriageway, edge-consistent with the junction polygons it meets.
        if subclass == "junction_area" || subclass == "carriageway_area" {
            // Only the graph-reconstructed surfaces draw. A hand-mapped
            // area:highway (a junction_area without origin=graph) often
            // covers a whole street, including the gap between the two
            // one-way halves of a dual carriageway: painted, it welded the
            // two reconstructed bodies into one mass with both inner edge
            // lines stranded inside it. The roadway is filled by the
            // reconstruction alone; the tag still ships and can be turned
            // back on here if a region without reconstruction needs it.
            guard subclass == "carriageway_area" || props["origin"]?.stringValue == "graph" else {
                return hiddenStyle
            }
            return junctionAreaStyle(cls: effectiveClass,
                                     tunnel: isTunnel,
                                     tile: tile,
                                     reconstructed: true)
        }
        // A surface parking lot: its own asphalt with a kerb, like a junction
        // area of the service tier, and from street zoom the synthesized comb
        // of parking-bay stripes on top.
        if subclass == "parking_area" {
            return parkingAreaStyle(tile: tile)
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
        let casingZoom = tileZoom >= 10 && isConstruction == false
        // Over a country or region view a road is a symbol, not a surface,
        // and it draws on the same principle as the country borders: one
        // point-locked pass in the generic ground path, butt ends, opaque
        // from the first frame it is visible. The previous overview attempt
        // kept the road machinery: its fade band held the skeleton
        // translucent exactly at the zooms it is the star, and translucent
        // wide round caps composited unevenly at every joint. Borders never
        // had either problem. From z10 (the casing era) the world width
        // takes over with the point floors as a safety net.
        if tileZoom <= 9 {
            switch effectiveClass {
            case "motorway":
                return overviewRoadStyle(fillKey: 56, widthPoints: 1.5, priority: 95,
                                         accent: isConstruction ? nil : SIMD4<Float>(0.427, 0.447, 0.478, 1.0),
                                         streetColor: roads.motorway,
                                         tunnel: isTunnel, construction: isConstruction)
            case "trunk":
                return overviewRoadStyle(fillKey: 54, widthPoints: 1.4, priority: 90,
                                         accent: isConstruction ? nil : SIMD4<Float>(0.478, 0.498, 0.525, 1.0),
                                         streetColor: roads.trunk,
                                         tunnel: isTunnel, construction: isConstruction)
            case "primary":
                return overviewRoadStyle(fillKey: 52, widthPoints: 1.1, priority: 80,
                                         accent: nil, streetColor: roads.primary,
                                         tunnel: isTunnel, construction: isConstruction)
            case "secondary":
                return overviewRoadStyle(fillKey: 50, widthPoints: 0.9, priority: 78,
                                         accent: nil, streetColor: roads.secondary,
                                         tunnel: isTunnel, construction: isConstruction)
            default:
                break
            }
        }
        // From here the width is the road's real carriageway, in metres
        // converted to this tile's units: at street zoom a six-lane avenue is
        // drawn six lanes wide, and the point floors below carry the class
        // through the zooms where that width is sub-pixel. Markings ride the
        // same fact, so they only appear where the surface can hold them.
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        let widthMetres = roadWidthUnits(cls: effectiveClass, props: props, tile: tile)
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
                             minimumWidthPoints: 2.2, maximumWidthPoints: 7.0, unitsPerMetre: unitsPerMetre,
                             markings: markings,
                             overviewAccent: isConstruction ? nil : SIMD4<Float>(0.427, 0.447, 0.478, 1.0),
                             construction: isConstruction)
        case "trunk":
            return roadStyle(fillKey: 54, color: roads.trunk, width: widthMetres, priority: 90, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 2.0, maximumWidthPoints: 6.5, unitsPerMetre: unitsPerMetre,
                             markings: markings,
                             overviewAccent: isConstruction ? nil : SIMD4<Float>(0.478, 0.498, 0.525, 1.0),
                             construction: isConstruction)
        case "primary":
            return roadStyle(fillKey: 52, color: roads.primary, width: widthMetres, priority: 80, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 1.6, maximumWidthPoints: 6.0, unitsPerMetre: unitsPerMetre, markings: markings, construction: isConstruction)
        case "secondary":
            return roadStyle(fillKey: 50, color: roads.secondary, width: widthMetres, priority: 78, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 1.2, maximumWidthPoints: 5.0, unitsPerMetre: unitsPerMetre, markings: markings, construction: isConstruction)
        case "tertiary":
            return roadStyle(fillKey: 48, color: roads.tertiary, width: widthMetres, priority: 74, casing: casingZoom, tunnel: isTunnel,
                             minimumWidthPoints: 1.0, maximumWidthPoints: 4.5, unitsPerMetre: unitsPerMetre, markings: markings, construction: isConstruction)
        case "minor":
            return roadStyle(fillKey: 44, color: roads.minor, width: widthMetres, priority: 50, casing: tileZoom >= 13, tunnel: isTunnel,
                             minimumWidthPoints: 0.9, maximumWidthPoints: 4.0, unitsPerMetre: unitsPerMetre, markings: markings)
        case "service":
            // A service road is one lane wide and has nothing to divide, so
            // it carries no markings. A parking aisle sits one step below
            // the rest of the tier: a parking lot owns its aisles (and eats
            // their ribbons), but must not eat the service roads that merely
            // pass along it, a bus lane mapped as its own way among them.
            let isParkingAisle = props["service"]?.stringValue == "parking_aisle"
            return roadStyle(fillKey: 42, color: roads.service, width: widthMetres, priority: isParkingAisle ? 45 : 46, casing: tileZoom >= 14, tunnel: isTunnel,
                             minimumWidthPoints: 0.7, maximumWidthPoints: 2.5, unitsPerMetre: unitsPerMetre)
        case "path", "track":
            // Park alleys and walkways (footway/path/track): a plain strip of
            // the ground color, no kerb and no dashes. Over land it is the
            // ground itself (the footway network is not a second road
            // system), and over a park, a square or water it reads as a pale
            // route across the surface. A kerb on a ground-colored strip
            // turned every path into a grey band wider than its interior.
            return roadStyle(fillKey: 40, color: roads.path, width: widthMetres, priority: 35, casing: false, tunnel: isTunnel,
                             minimumWidthPoints: 0.5, unitsPerMetre: unitsPerMetre)
        case "rail", "transit":
            return railStyle(subclass: subclass, tileZoom: tileZoom)
        case "ferry":
            return line(key: 41, color: configuration.layers.water, width: 4 * s, dashLength: 8, dashGap: 8)
        default:
            return roadStyle(fillKey: 43, color: roads.minor, width: widthMetres, priority: 40, casing: tileZoom >= 13, tunnel: isTunnel,
                             minimumWidthPoints: 0.9, unitsPerMetre: unitsPerMetre)
        }
    }

    /// The tile zoom a road class first draws at. Majors carry a country
    /// view; the minor network only means something near street level. The
    /// OpenMapTiles source ships most classes far earlier than they can read.
    private static func roadClassMinimumZoom(_ cls: String?) -> Int {
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

    /// Casing keys sort below every road fill (and above buildings at 30):
    /// below the separate-road zoom the generic ground path draws by
    /// ascending key, so this is what puts every casing under every fill,
    /// the same layering the separate-road phases produce at street zoom.
    private static func roadCasingKey(forFillKey fillKey: UInt8) -> UInt8 {
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

    /// Whether a feature is a pedestrian crossing, and whether it is painted.
    ///
    /// The tiles carry `crossing` on the footway that crosses the road, with
    /// `markings` naming the pattern where OSM says so. `marked` and
    /// `traffic_signals` are painted on the ground (a signalled crossing
    /// almost always is); `unmarked` is not, and `unknown` is the honest
    /// answer for a crossing nobody described, so neither gets a zebra.
    private static func crossingMarking(props: [String: MvtValue]) -> Bool? {
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
    private static let streetDetailMinimumTileZoom = 15

    /// A marked crossing: white stripes laid across the carriageway.
    ///
    /// The band is as deep as a crossing is on the ground and the stripes are
    /// derived from it, so the whole figure is a length rather than a screen
    /// pattern. It draws in the `detail` role, above every carriageway, and
    /// fades in on the markings' camera-zoom band with the rest of the paint.
    private func crosswalkStyle(marked: Bool, tile: Tile, shipped: Bool = false) -> FeatureStyle {
        guard marked else {
            // An unmarked crossing is a place to cross, not a thing to draw:
            // the footway underneath it is already on the map.
            return hiddenStyle
        }
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        let bandUnits = Self.crosswalkBandMetres * unitsPerMetre
        return FeatureStyle(
            key: Self.crosswalkKey,
            color: Self.roadMarkingColor,
            lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: bandUnits),
            lineRenderPasses: [
                LineRenderPass(key: Self.crosswalkKey,
                               color: Self.roadMarkingColor,
                               lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                               parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: bandUnits),
                               includeRoadLabelPath: false,
                               roadPassRole: .detail)
            ],
            roadClassPriority: Self.crosswalkClassPriority,
            roadDecorationKind: .zebraCrossing,
            isShippedRoadPaint: shipped
        )
    }

    /// How deep a crossing is along the road, in metres: the band the stripes
    /// fill. The stripe period is derived from it inside the builder, so the
    /// whole figure scales as one thing.
    private static let crosswalkBandMetres: Double = 4.0
    private static let crosswalkKey: UInt8 = 63
    /// A crossing sorts with the carriageway it is painted on, above every
    /// road fill: it is paint on the road, not a road.
    private static let crosswalkClassPriority = 96

    /// The opacity of everything a vehicular tunnel draws: its ribbon at
    /// the zooms a road is a line, and its road surface where the tiles
    /// ship one. A tunnel is a plain fill with this alpha and nothing else,
    /// no kerb, no dash, no paint, so the ground shows through it in
    /// whichever palette the map wears and the road network stays joined
    /// across it without pretending to be at grade. Eighty percent
    /// transparent: the tunnel is a hint of where the road goes, not a road.
    static let tunnelFillOpacity: Float = 0.2

    /// `color` with the tunnel opacity in place of its own alpha.
    private static func tunnelTone(_ color: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(color.x, color.y, color.z, tunnelFillOpacity)
    }

    /// Yellow road paint (a centre line that may not be crossed): muted in
    /// TONE like the white, and fully opaque like it (see roadMarkingColor).
    private static let roadMarkingYellowColor = SIMD4<Float>(0.93, 0.83, 0.44, 1.0)
    /// A solid line of paint draws visibly thicker than a broken one: on the
    /// map a solid line is a statement (an edge, a line not to cross), and at
    /// the dash's hairline weight it read as just another dash row.
    private static let solidMarkingWidthPoints: Float = 1.4
    /// A lane separator: one metre of paint, one and a half of gap (the
    /// source's own pattern for the line between two same-direction lanes).
    private static let shippedSeparatorDashMetres: Double = 1.0
    private static let shippedSeparatorGapMetres: Double = 1.5
    /// A dividing (centre) line: two metres of paint, four and a half of gap.
    private static let shippedDividingDashMetres: Double = 2.0
    private static let shippedDividingGapMetres: Double = 4.5
    /// A line of paint the source measured (`marking=...` in the road layer):
    /// the engine draws exactly the polyline the tiles ship, with the kind
    /// deciding stroke, colour and dash pattern. One `detail` pass, above
    /// every carriageway fill; `isShippedRoadPaint` keeps the road machinery
    /// (surface clipping, junction insets, stitching) off it, because the
    /// line already ends exactly where the paint ends on the ground.
    private func shippedMarkingStyle(kind: String,
                                     props: [String: MvtValue],
                                     tile: Tile) -> FeatureStyle {
        switch kind {
        case "crossing_marked":
            guard tile.z >= Self.streetDetailMinimumTileZoom else { return hiddenStyle }
            return crosswalkStyle(marked: true, tile: tile, shipped: true)
        case "bus_lane":
            // The lane's axis: the letter A stamped along it, feet toward
            // the driver, is what marks a dedicated lane on real asphalt.
            guard tile.z >= Self.streetDetailMinimumTileZoom else { return hiddenStyle }
            return busLaneLetterStyle()
        case "bus_stop_zigzag":
            // The stop's stretch of kerb: the yellow sawtooth of the bus
            // stop marking, folded from the shipped axis by the builder.
            guard tile.z >= Self.streetDetailMinimumTileZoom else { return hiddenStyle }
            return busStopZigzagStyle()
        case "crossing_unmarked":
            // A place to cross, not a thing to draw: same answer as for the
            // attribute-tagged unmarked crossings.
            return hiddenStyle
        case "edge":
            // The roadway edge is already drawn: every carriageway wears the
            // grey kerb along its outline. A white solid painted a step
            // inside it doubled the road's edge into two parallel strokes,
            // so the shipped edge line stays data-only. The paint in the
            // middle (dividing lines, separators) keeps drawing.
            return hiddenStyle
        case "dividing", "lane_separator":
            break
        default:
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
        let isYellow = props["paint"]?.stringValue?.lowercased() == "yellow" && kind != "lane_separator"
        let color = isYellow ? Self.roadMarkingYellowColor : Self.roadMarkingColor
        // Solid or dashed comes from the source where it says (`style`), with
        // the kind's own default behind it: a separator is dashed, a
        // dividing line dashed unless stated solid.
        let dashed: Bool
        switch props["style"]?.stringValue?.lowercased() {
        case "solid": dashed = false
        case "dashed": dashed = true
        default: dashed = true
        }
        // A key is a baked style, so every (kind, colour, solid-or-dashed)
        // triple carries its own: a solid line is wider than a dashed one,
        // and two features under one key must bake identically.
        let key: UInt8
        switch (kind, isYellow, dashed) {
        case ("lane_separator", _, true): key = 58
        case ("lane_separator", _, false): key = 64
        case ("dividing", false, true): key = 60
        case ("dividing", true, true): key = 61
        case ("dividing", false, false): key = 65
        case ("dividing", true, false): key = 66
        // 59, 62, 67 and 68 were the edge-line keys; retired with the edge
        // lines themselves, not to be reused for anything else.
        default: key = 60
        }
        let dashMetres: Double
        let gapMetres: Double
        switch kind {
        case "lane_separator":
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
        let geometry = TileMvtParser.ParseGeometryStyleData(lineWidth: ribbonUnits,
                                                            lineCapRound: false,
                                                            lineJoinRound: true)
        let pass = LineRenderPass(key: key,
                                  color: color,
                                  lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                                  lineWidthPoints: widthPoints,
                                  dashLengthPoints: dashed ? Float(dashMetres * unitsPerMetre) : 0,
                                  dashGapPoints: dashed ? Float(gapMetres * unitsPerMetre) : 0,
                                  dashInTileUnits: dashed,
                                  parseGeometryStyleData: geometry,
                                  includeRoadLabelPath: false,
                                  roadPassRole: .detail)
        return FeatureStyle(
            key: key,
            color: color,
            lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
            parseGeometryStyleData: geometry,
            lineRenderPasses: [pass],
            roadClassPriority: Self.crosswalkClassPriority,
            isShippedRoadPaint: true
        )
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
    private func junctionAreaStyle(cls: String?, tunnel: Bool, tile: Tile, reconstructed: Bool) -> FeatureStyle {
        let roads = configuration.layers.roads
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
        let surfaceKey = fillKey
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        let kerbWidth = 2 * Self.roadCasingMetresPerSide * unitsPerMetre
        var passes: [LineRenderPass] = []
        if tunnel == false, Self.drawsAutomobileKerb {
            passes.append(
                LineRenderPass(key: Self.roadCasingKey(forFillKey: fillKey),
                               color: roadCasingColor(from: classColor),
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: kerbWidth,
                                                                                             lineJoinRound: true),
                               includeRoadLabelPath: false,
                               roadPassRole: .casing)
            )
        }
        passes.append(
            LineRenderPass(key: surfaceKey,
                           color: color,
                           lowZoomFadeMask: roadLowZoomFadeMask,
                           parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100),
                           includeRoadLabelPath: false,
                           roadPassRole: .fill)
        )
        return FeatureStyle(
            key: surfaceKey,
            color: color,
            lowZoomFadeMask: roadLowZoomFadeMask,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100),
            lineRenderPasses: passes,
            roadClassPriority: priority,
            isRoadSurfaceArea: true,
            surfaceAreaCutsPaint: reconstructed
        )
    }

    /// A surface parking lot (`subclass=parking_area`): service-tier asphalt
    /// with the same kerb a junction area wears, plus, from the zoom where
    /// paint reads, a `detail` pass that the parser fills with the
    /// synthesized parking-bay comb (`ParkingBayGeometryBuilder`). The comb
    /// is a stylization, not a claim about mapped spaces, which OSM almost
    /// never carries; the polygon and its `orientation` hint are the facts.
    /// The surface clips the ribbons inside it (a parking aisle needs no kerb
    /// of its own across the lot) and never cuts anyone's paint.
    private func parkingAreaStyle(tile: Tile) -> FeatureStyle {
        let roads = configuration.layers.roads
        let fillKey: UInt8 = 42
        let color = roads.service
        let unitsPerMetre = Self.tileUnitsPerMetre(tile: tile)
        let kerbWidth = 2 * Self.roadCasingMetresPerSide * unitsPerMetre
        var passes: [LineRenderPass] = [
            LineRenderPass(key: Self.roadCasingKey(forFillKey: fillKey),
                           color: roadCasingColor(from: color),
                           lowZoomFadeMask: roadLowZoomFadeMask,
                           parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: kerbWidth,
                                                                                         lineJoinRound: true),
                           includeRoadLabelPath: false,
                           roadPassRole: .casing),
            LineRenderPass(key: fillKey,
                           color: color,
                           lowZoomFadeMask: roadLowZoomFadeMask,
                           parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100),
                           includeRoadLabelPath: false,
                           roadPassRole: .fill)
        ]
        // The comb from the zoom the lot itself ships at, like every other
        // figure painted on a road surface: a lot looks the same at z15 as
        // at z16, and the camera-zoom band decides how faint the stripes are.
        if tile.z >= Self.streetDetailMinimumTileZoom {
            passes.append(
                LineRenderPass(key: Self.parkingBayKey,
                               color: Self.roadMarkingColor,
                               lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                               lineWidthPoints: Self.roadMarkingWidthPoints,
                               parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(
                                   lineWidth: Double(Self.roadMarkingWidthPoints) * Self.roadMarkingRibbonUnitsPerPoint
                               ),
                               includeRoadLabelPath: false,
                               roadPassRole: .detail)
            )
        }
        return FeatureStyle(
            key: fillKey,
            color: color,
            lowZoomFadeMask: roadLowZoomFadeMask,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100),
            lineRenderPasses: passes,
            roadClassPriority: 45,
            roadDecorationKind: .parkingBays,
            isRoadSurfaceArea: true
        )
    }

    private static let parkingBayKey: UInt8 = 69

    /// The letter A along a dedicated bus lane: a polygon decoration in the
    /// detail role, like the zebra, in the plain marking paint. The line the
    /// tiles ship is the lane's axis with the direction of travel baked in;
    /// the builder does the stamping, and `isShippedRoadPaint` keeps the
    /// road machinery off the axis itself.
    private func busLaneLetterStyle() -> FeatureStyle {
        let geometry = TileMvtParser.ParseGeometryStyleData(lineWidth: 1)
        return FeatureStyle(
            key: Self.busLaneLetterKey,
            color: Self.roadMarkingColor,
            lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
            parseGeometryStyleData: geometry,
            lineRenderPasses: [
                LineRenderPass(key: Self.busLaneLetterKey,
                               color: Self.roadMarkingColor,
                               lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                               parseGeometryStyleData: geometry,
                               includeRoadLabelPath: false,
                               roadPassRole: .detail)
            ],
            roadClassPriority: Self.crosswalkClassPriority,
            roadDecorationKind: .busLaneLetter,
            isShippedRoadPaint: true
        )
    }

    private static let busLaneLetterKey: UInt8 = 71

    /// The yellow sawtooth at a public transport stop, same construction as
    /// the letter: a polygon decoration in the detail role, in the yellow
    /// road paint.
    private func busStopZigzagStyle() -> FeatureStyle {
        let geometry = TileMvtParser.ParseGeometryStyleData(lineWidth: 1)
        return FeatureStyle(
            key: Self.busStopZigzagKey,
            color: Self.roadMarkingYellowColor,
            lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
            parseGeometryStyleData: geometry,
            lineRenderPasses: [
                LineRenderPass(key: Self.busStopZigzagKey,
                               color: Self.roadMarkingYellowColor,
                               lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                               parseGeometryStyleData: geometry,
                               includeRoadLabelPath: false,
                               roadPassRole: .detail)
            ],
            roadClassPriority: Self.crosswalkClassPriority,
            roadDecorationKind: .busStopZigzag,
            isShippedRoadPaint: true
        )
    }

    private static let busStopZigzagKey: UInt8 = 77


    /// A road over a country or region view: a symbolic stroke, drawn through
    /// the point-locked line factory the borders use (see
    /// `FeatureStyle.pointLockedLine`). Tunnels and construction segments
    /// read as point-dashed corridors.
    private func overviewRoadStyle(fillKey: UInt8,
                                   widthPoints: Float,
                                   priority: Int,
                                   accent: SIMD4<Float>?,
                                   streetColor: SIMD4<Float>,
                                   tunnel: Bool,
                                   construction: Bool) -> FeatureStyle {
        // A tunnel is the same stroke at the tunnel opacity, not a dash: one
        // treatment for every zoom the tunnel draws at.
        let dashed = construction && tunnel == false
        let baseColor = accent ?? streetColor
        let baseStreetColor = accent != nil ? streetColor : nil
        return FeatureStyle.pointLockedLine(
            key: fillKey,
            color: tunnel ? Self.tunnelTone(baseColor) : baseColor,
            streetColor: tunnel ? baseStreetColor.map(Self.tunnelTone) : baseStreetColor,
            widthPoints: widthPoints,
            dashLengthPoints: dashed ? 4.0 : 0,
            dashGapPoints: dashed ? 2.5 : 0,
            roadClassPriority: priority
        )
    }

    private func roadStyle(fillKey: UInt8,
                           color: SIMD4<Float>,
                           width: Double,
                           priority: Int,
                           casing: Bool,
                           tunnel: Bool,
                           minimumWidthPoints: Float = 0,
                           maximumWidthPoints: Float = 0,
                           unitsPerMetre: Double = 0,
                           markings: RoadMarkings = .none,
                           overviewAccent: SIMD4<Float>? = nil,
                           construction: Bool = false) -> FeatureStyle {
        // A tunnel is the plain ribbon at the tunnel opacity: no dash, no
        // kerb, no paint (both are skipped below). The construction
        // point-dash only applies to surface segments.
        let fillGeometry = makeRoadGeometry(width: width)
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
        // The floor stops mattering once the world width exceeds it, so the
        // casing keeps its proportion by flooring half a point above the fill.
        let casingFloor = minimumWidthPoints > 0 ? minimumWidthPoints + 0.5 : 0

        var passes: [LineRenderPass] = []
        if casing, tunnel == false, Self.drawsAutomobileKerb {
            // The casing is a kerb: a fixed margin of ground on each side of
            // the carriageway, not a fraction of it. As a fraction it was a
            // few units on a symbolic width and metres wide on a true one,
            // which turns every street into a dark-edged ribbon.
            let casingWidth = width + 2 * Self.roadCasingMetresPerSide * unitsPerMetre
            passes.append(
                LineRenderPass(key: Self.roadCasingKey(forFillKey: fillKey),
                               color: roadCasingColor(from: fillColor),
                               streetColor: fillStreetColor.map(roadCasingColor(from:)),
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               minimumWidthPoints: casingFloor,
                               maximumWidthPoints: maximumWidthPoints > 0 ? maximumWidthPoints + 1.0 : 0,
                               parseGeometryStyleData: makeRoadGeometry(width: casingWidth),
                               includeRoadLabelPath: false,
                               roadPassRole: .casing)
            )
        }
        passes.append(
            LineRenderPass(key: fillKey,
                           color: fillColor,
                           streetColor: fillStreetColor,
                           lowZoomFadeMask: roadLowZoomFadeMask,
                           dashLengthPoints: constructionDash?.length ?? 0,
                           dashGapPoints: constructionDash?.gap ?? 0,
                           minimumWidthPoints: minimumWidthPoints,
                           maximumWidthPoints: maximumWidthPoints,
                           parseGeometryStyleData: fillGeometry,
                           includeRoadLabelPath: false,
                           roadPassRole: .fill)
        )
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
            passes.append(
                LineRenderPass(key: Self.roadMarkingKey(forFillKey: fillKey),
                               color: Self.roadMarkingColor,
                               lowZoomFadeMask: Self.roadMarkingLowZoomFadeMask,
                               lineWidthPoints: Self.roadMarkingWidthPoints,
                               dashLengthPoints: Float(Self.roadMarkingDashMetres * unitsPerMetre),
                               dashGapPoints: Float(Self.roadMarkingGapMetres * unitsPerMetre),
                               dashInTileUnits: true,
                               parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(
                                   lineWidth: markingRibbonUnits,
                                   lineCapRound: false,
                                   lineJoinRound: true,
                                   endInset: markingEndInset,
                                   lateralOffset: markingOffset
                               ),
                               includeRoadLabelPath: false,
                               roadPassRole: .detail)
            )
        }

        return FeatureStyle(
            key: fillKey,
            color: fillColor,
            streetColor: fillStreetColor,
            lowZoomFadeMask: roadLowZoomFadeMask,
            parseGeometryStyleData: fillGeometry,
            lineRenderPasses: passes,
            roadClassPriority: priority
        )
    }

    private func buildingStyle(tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= 13 else {
            return fallbackStyle
        }
        // 3D extruded buildings driven by OpenMapTiles render_height / render_min_height.
        return FeatureStyle(
            key: 30,
            color: configuration.features.buildingFillColor,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0),
            usesExtrusion: true,
            extrusionHeightScale: 8.0,
            extrusionAnchorZoom: 16
        )
    }

    private func railStyle(subclass: String?, tileZoom: Int) -> FeatureStyle {
        // Subway lines (railway=subway) run in tunnels under buildings/parks and
        // read as a confusing dashed line, so we hide them. Surface rail (rail,
        // tram, light_rail, monorail) stays dashed.
        if subclass == "subway" {
            return hiddenStyle
        }
        let s = roadWidthScale(tileZoom: tileZoom)
        return FeatureStyle(
            key: 46,
            color: configuration.layers.roads.rail,
            lowZoomFadeMask: roadLowZoomFadeMask,
            minimumWidthPoints: 0.7,
            parseGeometryStyleData: makeDashedRoadGeometry(width: 4.0 * s, dashLength: 8, dashGap: 8),
            roadClassPriority: 30
        )
    }

    /// The equatorial circumference the Web Mercator tile grid is built on.
    private static let equatorialCircumferenceMetres: Double = 40_075_016.686
    /// The canonical tile coordinate space every parsed geometry lives in
    /// (`TileMvtParser.tileExtent`).
    private static let tileExtentUnits: Double = 4096

    /// Tile units per ground metre for one tile.
    ///
    /// A road's width is a fact about the ground, so the style states it in
    /// metres and converts here. Web Mercator's scale is a function of
    /// latitude, taken at the tile's own centre, and the tile's zoom sets how
    /// much ground its 4096 units span. Doing the conversion per tile is what
    /// makes a road the same width on screen whichever zoom's tile happens to
    /// serve it: a street drawn from a coarse tile in the distance and the
    /// same street drawn from a native tile underfoot agree, where a width
    /// stated directly in tile units would differ by the zoom ratio between
    /// them.
    private static func tileUnitsPerMetre(tile: Tile) -> Double {
        let tilesCount = Double(1 << max(0, tile.z))
        let normalizedY = (Double(tile.y) + 0.5) / tilesCount
        let latitudeRadians = atan(sinh(Double.pi * (1.0 - 2.0 * normalizedY)))
        let groundSpanMetres = equatorialCircumferenceMetres * cos(latitudeRadians) / tilesCount
        guard groundSpanMetres > 0.0001 else {
            return 0
        }
        return tileExtentUnits / groundSpanMetres
    }

    /// Carriageway width in metres, from the lane count the tiles carry.
    ///
    /// `lanes` is per way, so a dual carriageway arrives as two features and
    /// each gets its own width. Where the tag is missing the class states a
    /// typical lane count instead, which is what the width used to be based
    /// on implicitly.
    ///
    /// The lane width is the whole road's width divided by its lanes, which
    /// is more than the painted lane: a street is lanes plus the parking
    /// strip along it, plus the gutter to the kerb. OSM's `lanes` counts the
    /// marked through lanes and nothing else, so a two-lane city street with
    /// cars parked on both sides is around 12 m wide, not 6.5, and a width of
    /// 3.25 m per counted lane drew every such street at half its width.
    /// The carriageway width the tiles state outright, in metres, or nil.
    ///
    /// `width` arrives in decimetres and is measured by the same model that
    /// builds the junction polygons (the street's cross-section, lane by
    /// lane), which is the whole point: a junction polygon inside ribbons of
    /// a DIFFERENT width model floats like a puddle, because its straight
    /// cuts land in the middle of asphalt instead of on the ribbon's edge.
    /// One width model, one geometry.
    private func statedWidthMetres(props: [String: MvtValue]) -> Double? {
        guard let decimetres = parseIntValue(props["width"]), decimetres > 0 else {
            return nil
        }
        let metres = Double(decimetres) / 10.0
        // A width outside these bounds is a data accident, not a road.
        guard metres >= 2.0, metres <= 60.0 else { return nil }
        return metres
    }

    private func roadWidthMetres(cls: String?, props: [String: MvtValue]) -> Double {
        if let stated = statedWidthMetres(props: props) {
            return stated
        }
        let laneWidthMetres: Double
        switch cls {
        case "motorway", "trunk", "primary":
            laneWidthMetres = 4.0
        case "secondary", "tertiary":
            laneWidthMetres = 4.5
        case "minor":
            laneWidthMetres = 5.0
        case "service":
            laneWidthMetres = 4.0
        default:
            // Footways, tracks and anything unclassified: not a carriageway,
            // so a fixed walkable width rather than a lane count.
            return 2.0
        }
        return Double(roadLaneCount(cls: cls, props: props)) * laneWidthMetres
    }

    /// The lane count a road draws with: the tiles' `lanes` within a sane
    /// range (the tag carries occasional nonsense, and a road hundreds of
    /// metres wide would swamp the frame), else a typical count per class.
    private func roadLaneCount(cls: String?, props: [String: MvtValue]) -> Int {
        let defaultLanes: Int
        switch cls {
        case "motorway": defaultLanes = 4
        case "trunk", "primary": defaultLanes = 3
        case "secondary", "tertiary", "minor": defaultLanes = 2
        default: defaultLanes = 1
        }
        return min(max(parseIntValue(props["lanes"]) ?? defaultLanes, 1), 12)
    }

    /// What paint an automobile road carries.
    enum RoadMarkings {
        case none
        /// A two-way street: one dashed line down the middle. The boundaries
        /// inside each direction are not drawn: placing them needs the split
        /// between the directions, and the tiles carry only the total.
        case centreDivider
        /// A one-way carriageway of several lanes: a dashed line on each
        /// boundary between lanes, none in the middle of the road.
        case laneLines(laneCount: Int)
    }

    /// Lateral offsets of every boundary between lanes, in tile units from
    /// the centreline. A road of `laneCount` lanes has `laneCount - 1` of
    /// them, evenly spaced; with an even count one of them is the centre.
    private static func laneBoundaryOffsets(width: Double, laneCount: Int) -> [Double] {
        let lanes = max(laneCount, 1)
        guard lanes >= 2 else { return [] }
        let laneWidth = width / Double(lanes)
        return (1..<lanes).map { -width * 0.5 + laneWidth * Double($0) }
    }

    /// The width of a road's carriageway in the tile's own units.
    private func roadWidthUnits(cls: String?,
                                props: [String: MvtValue],
                                tile: Tile) -> Double {
        roadWidthMetres(cls: cls, props: props) * Self.tileUnitsPerMetre(tile: tile)
    }

    /// How much wider than the carriageway the casing draws, in metres per
    /// side: the kerb line, not a proportion of the road. A proportional
    /// casing was invisible on a symbolic width and metres wide on a true
    /// one.
    private static let roadCasingMetresPerSide: Double = 0.7

    /// From this tile zoom a drive-tier road is wide enough on screen to hold
    /// lane markings: below it the dashes would be noise inside a road only a
    /// few points across.
    private static let roadMarkingsMinimumTileZoom = 13

    /// Whether a road class is painted at all.
    ///
    /// The through hierarchy is: an avenue carries a centre line and lane
    /// lines, and a map that leaves them out reads as unfinished. Everything
    /// below it does not: a residential street, a courtyard proezd, a service
    /// alley, a track and a footway have bare asphalt, and painting them
    /// covers the map in dashes that are not on the ground.
    private static func roadClassCarriesMarkings(_ cls: String?) -> Bool {
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
    private static let roadMarkingColor = SIMD4<Float>(0.97, 0.97, 0.96, 1.0)
    private static let roadMarkingWidthPoints: Float = 0.9
    /// A city broken lane line: three metres of paint, six of gap.
    private static let roadMarkingDashMetres: Double = 3.0
    private static let roadMarkingGapMetres: Double = 6.0
    /// Tile units of marking ribbon per point of stroke. Markings live on
    /// z15+ tiles, where a unit is a few centimetres, so a much tighter
    /// provisioning than the overview lines' 32 still hosts the stroke on a
    /// dense display, and a tighter ribbon is a shorter corner wedge.
    private static let roadMarkingRibbonUnitsPerPoint: Double = 8

    /// Markings sort one above their fill, out of the way of every other
    /// key the style uses. The `detail` pass role is what actually puts them
    /// over the carriageway; the key only has to stay unique.
    private static func roadMarkingKey(forFillKey fillKey: UInt8) -> UInt8 {
        fillKey &+ 1
    }

    /// Multiplier applied to the (z14+) base road widths so roads are thin hairlines
    /// at country/regional zooms and reach full width at street level.
    private func roadWidthScale(tileZoom: Int) -> Double {
        switch tileZoom {
        case ...7: return 0.15
        case 8: return 0.22
        case 9: return 0.30
        case 10: return 0.40
        case 11: return 0.52
        case 12: return 0.68
        case 13: return 0.84
        default: return 1.0
        }
    }

    /// Below this tile zoom the map is a planet or continent view: regional
    /// (admin 3-4) borders are pure clutter there and stay hidden.
    private static let regionalBoundaryMinimumZoom = 4

    private func boundaryStyle(props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        let adminLevel = parseIntValue(props["admin_level"]) ?? 4
        guard adminLevel <= 4 else {
            return hiddenStyle
        }
        if adminLevel > 2, tileZoom < Self.regionalBoundaryMinimumZoom {
            return hiddenStyle
        }
        // Borders draw through the point-locked line factory (see
        // FeatureStyle.pointLockedLine, which documents the principle they
        // originated): width and dash pattern in layout points, opaque, butt
        // ends, ribbon provisioned to host the width.
        let key: UInt8 = adminLevel <= 2 ? 102 : 100
        // Regional (admin 3-4) borders at country overview zooms: the
        // saturated purple that separates districts at street zooms is the
        // one cold hue in a whole-region frame and reads as scribble there.
        // Until the region zooms the line lightens and turns half
        // transparent; national borders keep their full weight throughout.
        var color = configuration.layers.boundary
        if adminLevel > 2, tileZoom <= 6 {
            let softened = color + (SIMD4<Float>(1, 1, 1, color.w) - color) * 0.35
            color = SIMD4<Float>(softened.x, softened.y, softened.z, color.w * 0.6)
        }
        // suppressPolygonFill: borders are drawn as lines only. Some features
        // (Native American reservations) arrive as polygons; their area must
        // not be filled, otherwise you get solid purple blobs.
        return FeatureStyle.pointLockedLine(
            key: key,
            color: color,
            widthPoints: adminLevel <= 2 ? 1.6 : 1.1,
            dashLengthPoints: 7.0,
            dashGapPoints: 3.5,
            suppressPolygonFill: true
        )
    }

    // MARK: - Labels

    private func placeLabelStyle(props: [String: MvtValue]) -> FeatureStyle {
        let cls = props["class"]?.stringValue?.lowercased()
        var appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance
        switch cls {
        case "continent", "country":
            appearance = configuration.labels.country
        case "state", "province":
            var a = configuration.labels.country
            a.sizePoints -= 2
            appearance = a
        case "city":
            appearance = configuration.labels.city
        case "town":
            appearance = configuration.labels.town
        default: // village, hamlet, suburb, quarter, neighbourhood, ...
            var a = configuration.labels.town
            a.sizePoints -= 1.5
            a.weight = .thin
            appearance = a
        }
        // Capitals in the label-priority contract: `capital` no longer
        // travels in the tiles, a national capital is a rank-1 city.
        if cls == "city", parseIntValue(props["rank"]) == 1 {
            appearance.sizePoints += 1.5
            appearance.weight = .bold
        }
        return pointLabel(key: 70, appearance: appearance)
    }

    private func waterLabelStyle(props: [String: MvtValue]) -> FeatureStyle {
        var appearance = configuration.labels.water
        switch props["class"]?.stringValue?.lowercased() {
        case "ocean":
            appearance.sizePoints += 3
        case "sea":
            appearance.sizePoints += 1.5
        default:
            break
        }
        return pointLabel(key: 73, appearance: appearance)
    }

    // POI: both the icon circle and the label are tinted in the venue category
    // color. The color flows through LabelTextStyle.fillColor, used by both the
    // icon background (PoiIconStyleUniform.backgroundColor) and the text fill;
    // the icon glyph is white. All POIs share one key (72): runs are grouped by
    // full style identity (weight + colors), so different categories land in
    // separate draw runs.
    private func poiLabelStyle(props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        // POI appearance is derived from budget and priorities, with no
        // absolute zoom ramps: a label is visible once its effective rank fits
        // the grid-cell budget, and the budget quadruples with each zoom of
        // overzoom, exactly like the tile's screen area. The decision collapses
        // into a static threshold minCameraZoom = tile.z + log4(effRank / budget),
        // which the runtime and collisions apply by camera zoom. Classes define
        // a priority offset in rank units rather than zooms, so the approach
        // does not depend on the source maxzoom: switching sources shifts the
        // thresholds automatically via tile.z.
        let cls = props["class"]?.stringValue?.lowercased()
        let subclass = props["subclass"]?.stringValue?.lowercased()
        let rank = Double(parseIntValue(props["rank"]) ?? Self.poiUnrankedRank)
        let effectiveRank = max(Self.poiNativeCellBudget,
                                rank + Self.poiClassRankBias(cls: cls, subclass: subclass))
        var minCameraZoom = Float(tileZoom)
            + Float(log2(effectiveRank / Self.poiNativeCellBudget) / 2.0)
        let isIconless = poiSpriteResolver.resolve(attributes: props, layerName: "poi") == nil
        if isIconless {
            // A category the icon set does not know (an office, a company, a
            // monument, a named building) has nothing to draw but its name,
            // and in a city centre those names outnumber everything else: bare
            // text over the buildings, saying nothing about what the place is.
            // By default they are left out entirely; a configuration that
            // wants them back gets them from the iconless zoom floor.
            guard configuration.labelVisibility.poiRequiresIcon == false else {
                return hiddenStyle
            }
            minCameraZoom = max(minCameraZoom, Float(configuration.labelVisibility.poiIconlessMinimumZoom))
        }
        minCameraZoom = min(minCameraZoom, Float(tileZoom) + Self.poiMaximumOverzoomAppearanceDelay)
        // The global POI floor comes after the overzoom-delay cap on purpose:
        // the cap bounds rank-derived delays, while the floor is an absolute
        // visibility gate that may exceed it (up to hiding POIs entirely).
        minCameraZoom = max(minCameraZoom, Float(configuration.labelVisibility.poiMinimumZoom))

        var appearance = configuration.labels.poi
        appearance.fillColor = poiCategoryColor(cls: cls, subclass: subclass)
        return pointLabel(key: 72, appearance: appearance, minCameraZoom: minCameraZoom)
    }

    /// Rank grid-cell budget at the tile's NATIVE zoom: rank <= budget is
    /// visible as soon as the tile appears; each zoom of overzoom quadruples the budget.
    private static let poiNativeCellBudget = 1.0

    /// Rank for features without a rank attribute. The label-priority contract
    /// says an absent rank means the least important thing in its layer, so it
    /// lands at the reveal cap's tail (the profile's rank cap), not mid-tail.
    private static let poiUnrankedRank = 64

    /// Reveal ceiling: the neutral tail of the cap (rank 64) is exhausted
    /// exactly by tile.z + 3; positively offset infrastructure is clamped to
    /// arrive by tile.z + 3.5. There is nothing left to pull from the tile deeper than that.
    private static let poiMaximumOverzoomAppearanceDelay: Float = 3.5

    /// Class priority offsets in rank units (zoom-agnostic). Anchors are
    /// pushed negative and visible from the tile's birth, urban fabric comes
    /// slightly before neutral commerce, decorative greenery slightly later,
    /// street infrastructure ~two zooms later than the neutral classes.
    private static let poiMajorClasses: Set<String> = [
        "hospital", "railway", "aerodrome", "university", "college", "stadium",
        "museum", "zoo", "attraction", "harbor", "monument", "castle"
    ]
    private static let poiCommunityClasses: Set<String> = [
        "school", "theatre", "cinema", "lodging", "town_hall", "townhall",
        "library", "police", "fire_station", "pharmacy", "grocery", "park",
        "place_of_worship", "post", "bank", "campsite"
    ]
    private static let poiLateClasses: Set<String> = [
        "garden", "playground", "swimming_pool", "kindergarten", "sport"
    ]
    private static let poiInfrastructureClasses: Set<String> = [
        "bus", "bicycle_rental", "bicycle_rent", "parking", "fuel",
        "charging_station", "car", "car_rental", "atm"
    ]

    private static func poiClassRankBias(cls: String?, subclass: String?) -> Double {
        func bias(_ value: String?) -> Double? {
            guard let value else { return nil }
            if poiMajorClasses.contains(value) { return -1_000 }
            if poiCommunityClasses.contains(value) { return -4 }
            if poiLateClasses.contains(value) { return 8 }
            if poiInfrastructureClasses.contains(value) { return 40 }
            return nil
        }
        return bias(subclass) ?? bias(cls) ?? 0
    }

    private func poiCategoryColor(cls: String?, subclass: String?) -> SIMD3<Float> {
        switch cls ?? subclass {
        case "restaurant", "fast_food", "food_court", "ice_cream":
            return SIMD3<Float>(0.85, 0.40, 0.12)   // food: orange
        case "cafe", "bakery":
            return SIMD3<Float>(0.58, 0.37, 0.18)   // coffee/bakery: brown
        case "bar", "pub", "beer", "alcohol_shop", "nightclub", "wine":
            return SIMD3<Float>(0.62, 0.16, 0.34)   // bar: wine red
        case "shop", "grocery", "supermarket", "mall", "clothing_store", "convenience",
             "gift", "hairdresser", "hardware", "laundry", "car", "florist", "jewelry", "shoe":
            return SIMD3<Float>(0.16, 0.44, 0.78)   // shops: blue
        case "lodging":
            return SIMD3<Float>(0.66, 0.26, 0.60)   // hotels: magenta
        case "hospital", "pharmacy", "doctors", "dentist", "clinic":
            return SIMD3<Float>(0.82, 0.22, 0.26)   // health: red
        case "school", "college", "university", "kindergarten", "library":
            return SIMD3<Float>(0.22, 0.46, 0.52)   // education: teal
        case "museum", "art_gallery", "gallery", "attraction", "artwork", "theatre", "music", "cinema":
            return SIMD3<Float>(0.46, 0.30, 0.66)   // culture: violet
        case "park", "garden", "stadium", "pitch", "sport", "swimming", "golf", "playground", "picnic_site":
            return SIMD3<Float>(0.22, 0.54, 0.30)   // leisure/nature: green
        case "bus", "railway", "airport", "aerialway", "fuel", "car_rental", "parking", "harbor", "ferry_terminal":
            return SIMD3<Float>(0.32, 0.42, 0.55)   // transport: blue-gray
        case "bank", "post", "office", "town_hall", "police", "fire_station", "government", "atm":
            return SIMD3<Float>(0.40, 0.44, 0.52)   // offices/public services: gray-blue
        default:
            return configuration.labels.poi.fillColor  // everything else: default dark
        }
    }

    private func roadLabelStyle(cls: String?) -> FeatureStyle {
        FeatureStyle(
            key: 90,
            color: SIMD4<Float>(0, 0, 0, 0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 1),
            includeRoadLabelPath: true,
            roadClassPriority: roadLabelPriority(cls: cls),
            roadLabelTextStyle: labelTextStyle(key: 90, appearance: configuration.labels.road)
        )
    }

    private func houseNumberAppearance() -> ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance {
        var appearance = configuration.labels.poi
        // The densest label class, and the one the readable floor moves most:
        // 6 points was decoration rather than information, and at the floor each
        // one is legible while collision thins out the rest.
        appearance.sizePoints = 6
        appearance.fillColor = SIMD3<Float>(0.55, 0.53, 0.50)
        return appearance
    }

    // MARK: - Builders

    /// Transparent no-op fill for known-but-unstyled area features (keeps them off
    /// the red debug fallback while still consuming the feature).
    private var hiddenStyle: FeatureStyle {
        FeatureStyle(
            key: fallbackKey,
            color: SIMD4<Float>(0, 0, 0, 0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    /// The OpenMapTiles `park` layer. `national_park`/`nature_reserve` are real green
    /// space; `protected_area` is a broad heritage/administrative designation that
    /// often blankets whole city centres (e.g. Moscow's historic core) - painting it
    /// green makes the entire city read as a park, so it is not drawn as green.
    private func parkLayerStyle(cls: String?, subclass: String?) -> FeatureStyle {
        // The park layer covers green areas. Paint explicit parks/gardens/reserves
        // green (the class may be Cyrillic: "национальный_парк",
        // "природно-исторический_парк", ...). Large protected areas without a park
        // attribute (protected_area, "особо охраняемая ...", nature monuments) are
        // hidden to avoid flooding the map with green.
        let kind = "\(cls ?? "") \(subclass ?? "")"
        let greenKeywords = ["park", "парк", "garden", "сад", "reserve", "заповедник", "nature"]
        if greenKeywords.contains(where: { kind.contains($0) }) {
            return polygon(key: 16, color: configuration.layers.grass)
        }
        return hiddenStyle
    }

    private func polygon(key: UInt8,
                         color: SIMD4<Float>,
                         streetColor: SIMD4<Float>? = nil) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
            streetColor: streetColor,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    private func line(key: UInt8,
                      color: SIMD4<Float>,
                      width: Double,
                      dashLength: Double = 0,
                      dashGap: Double = 0,
                      minimumWidthPoints: Float = 0) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
            minimumWidthPoints: minimumWidthPoints,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: width,
                                                                         lineCapRound: true,
                                                                         lineJoinRound: true,
                                                                         dashLength: dashLength,
                                                                         dashGap: dashGap)
        )
    }

    private func pointLabel(key: UInt8,
                            appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance,
                            minCameraZoom: Float = 0) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: SIMD4<Float>(0, 0, 0, 0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0),
            labelTextStyle: labelTextStyle(key: Int(key), appearance: appearance),
            labelMinCameraZoom: minCameraZoom
        )
    }

    /// Road border = the fill colour darkened and made fully opaque - a border of
    /// the same hue but darker, never see-through, drawn under the lighter fill.
    /// The step is small and uniform across the channels, so an asphalt-grey
    /// fill keeps its neutral hue in the edge (a channel-biased step would
    /// tint the casing against the fill) and the edge defines the street
    /// without drawing a dark net over the city.
    private func roadCasingColor(from fill: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(fill.x - 0.13, 0.0),
                     max(fill.y - 0.13, 0.0),
                     max(fill.z - 0.13, 0.0),
                     1.0)
    }

    private func makeRoadGeometry(width: Double) -> TileMvtParser.ParseGeometryStyleData {
        TileMvtParser.ParseGeometryStyleData(lineWidth: width, lineCapRound: true, lineJoinRound: true)
    }

    private func makeDashedRoadGeometry(width: Double,
                                        dashLength: Double,
                                        dashGap: Double) -> TileMvtParser.ParseGeometryStyleData {
        TileMvtParser.ParseGeometryStyleData(lineWidth: width,
                                             lineCapRound: true,
                                             lineJoinRound: false,
                                             dashLength: dashLength,
                                             dashGap: dashGap)
    }

    private func labelTextStyle(key: Int,
                                appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance) -> LabelTextStyle {
        LabelTextStyle(key: key,
                       fillColor: appearance.fillColor,
                       strokeColor: appearance.strokeColor,
                       haloEm: appearance.haloEm,
                       sizePoints: LabelTypeScale.clamped(appearance.sizePoints),
                       weight: appearance.weight)
    }

    private func roadLabelPriority(cls: String?) -> Int {
        switch cls {
        case "motorway": return 95
        case "trunk": return 90
        case "primary": return 80
        case "secondary": return 78
        case "tertiary": return 74
        case "minor": return 50
        default: return 30
        }
    }

    // MARK: - Property helpers

    private func parseIntValue(_ value: MvtValue?) -> Int? {
        switch value {
        case .int(let number), .sint(let number):
            return Int(number)
        case .uint(let number):
            return Int(number)
        case .double(let number):
            return Int(number)
        case .float(let number):
            return Int(number)
        case .string(let text):
            return Int(text.trimmingCharacters(in: .whitespaces))
        case .bool, .absent, nil:
            return nil
        }
    }
}
