// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Default style for the OpenMapTiles-schema first-party provider. Visually in
/// the spirit of `MapboxDefaultMapStyle`, but reading the OpenMapTiles layer and
/// field contract (`class`/`subclass`/`brunnel`/`admin_level`/`rank`/`capital`).
final class ImmersiveMapTilesDefaultMapStyle: ImmersiveMapStyle {
    private static let implementationRevision: UInt32 = 36

    private let fallbackKey: UInt8 = 0
    /// Roads opt into the engine's z3->4 camera-zoom fade band, so the major
    /// classes ease in over the globe instead of popping with the z4 tiles.
    private let roadLowZoomFadeMask: Float = 2.0
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
        let cls = props["class"]?.stringValue.lowercased()
        let subclass = props["subclass"]?.stringValue.lowercased()

        switch layer {
        case "background":
            // Synthetic full-tile base quad the engine emits per tile. OpenMapTiles
            // has no land polygon, so this is what paints the land; without it the
            // base falls through to the red debug fallback. The overview tone
            // hands over to the street land gradually (streetPaletteBlend), so
            // no single zoom flips the whole ground color.
            let overviewColor = z <= massiveOverviewMaximumZoom
                ? configuration.globalLandcover.grass
                : configuration.globalLandcover.land
            return polygon(key: 1,
                           color: blend(overviewColor,
                                        toward: configuration.layers.land,
                                        amount: Self.streetPaletteBlend(tileZoom: z)))
        case "water":
            // Same bridge for water: the saturated globe blue eases into the
            // pale street blue across the handover zooms instead of snapping.
            return polygon(key: 20,
                           color: blend(configuration.globalLandcover.water,
                                        toward: configuration.layers.water,
                                        amount: Self.streetPaletteBlend(tileZoom: z)))
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
            return transportationStyle(cls: cls, props: props, tileZoom: z)
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
            return polygon(key: 11, color: configuration.layers.wood)
        case "grass":
            // OSM tags countless small courtyards/verges as generic grass; at city
            // zooms suppress those (keep only real green-space subclasses) so they
            // don't tint the whole city.
            if tileZoom >= 13, isGenericGrassSubclass(subclass) {
                return hiddenStyle
            }
            return polygon(key: 12, color: configuration.layers.grass)
        case "farmland":
            return polygon(key: 13, color: configuration.layers.farmland)
        case "wetland":
            return polygon(key: 14, color: configuration.layers.wetland)
        case "ice":
            return polygon(key: 17, color: configuration.layers.ice)
        case "sand":
            return polygon(key: 18, color: configuration.layers.sand)
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
        // In the biomes' final zoom the street palette is already arriving:
        // washing them toward the street land makes their disappearance at
        // the next zoom a small step instead of the green world vanishing.
        let street = Self.streetPaletteBlend(tileZoom: tileZoom)
        func washed(_ color: SIMD4<Float>) -> SIMD4<Float> {
            blend(color, toward: configuration.layers.land, amount: street)
        }
        switch cls {
        case "land":
            return polygon(key: 2, color: washed(blend(colors.land, toward: vegetationBase, amount: amount)))
        case "barren":
            return polygon(key: 3, color: washed(colors.barren))
        case "grass", "shrub", "moss":
            return polygon(key: 4, color: washed(colors.grass))
        case "crop":
            return polygon(key: 5, color: washed(blend(colors.crop, toward: vegetationBase, amount: amount)))
        case "forest":
            return polygon(key: 6, color: washed(blend(colors.forest, toward: vegetationBase, amount: amount * 0.75)))
        case "wetland", "mangroves":
            return polygon(key: 7, color: washed(blend(colors.wetland, toward: vegetationBase, amount: amount)))
        case "snow":
            return polygon(key: 8, color: colors.snow)
        default:
            // urban / water: leave to the background and water layers.
            return hiddenStyle
        }
    }

    /// How far the ground palette has handed over from the overview set (the
    /// soft-biome greens, the saturated globe water) to the street set (the
    /// near-white land base, the pale water) at a tile zoom. The two sets
    /// used to switch in one step at z9/z10, together with the biome
    /// polygons vanishing there (the tile service merges WorldCover only
    /// through z9), which flipped the whole map from a green world to a
    /// white one at a single zoom. Spreading the handover across z9-z12
    /// turns the cliff into steps small enough to read as a gradual change.
    private static func streetPaletteBlend(tileZoom: Int) -> Float {
        switch tileZoom {
        case ...8: return 0.0
        case 9: return 0.3
        case 10: return 0.65
        case 11: return 0.85
        default: return 1.0
        }
    }

    /// How far the vegetation classes blend toward the shared tone at a tile
    /// zoom: 1 is the full massive-overview merge, 0 the unmixed palette.
    private static func vegetationBlendAmount(tileZoom: Int) -> Float {
        switch tileZoom {
        case ...2: return 1.0
        case 3: return 0.65
        case 4: return 0.5
        case 5: return 0.4
        case 6: return 0.3
        case 7: return 0.2
        case 8: return 0.1
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

    private func waterwayStyle(cls: String?, props: [String: VectorTile_Tile.Value]) -> FeatureStyle {
        // Underground/culverted waterways (brunnel=tunnel, e.g. the Neglinnaya
        // under the Alexander Garden) are invisible in reality, so we hide them.
        if props["brunnel"]?.stringValue.lowercased() == "tunnel" {
            return hiddenStyle
        }
        let width: Double
        switch cls {
        case "river", "canal":
            width = 2.5
        case "stream":
            width = 1.4
        default:
            width = 1.0
        }
        return line(key: 22, color: configuration.layers.water, width: width)
    }

    private func transportationStyle(cls: String?,
                                     props: [String: VectorTile_Tile.Value],
                                     tileZoom: Int) -> FeatureStyle {
        let brunnel = props["brunnel"]?.stringValue.lowercased()
        let isTunnel = brunnel == "tunnel"
        let subclass = props["subclass"]?.stringValue.lowercased()
        let roads = configuration.layers.roads
        // A class draws only from the zoom where it can carry meaning: over a
        // country or regional view every road the tile ships is a sub-pixel
        // hairline, and drawing all of them just greys the map. Majors appear
        // first, the minor network fills in toward street level.
        guard tileZoom >= Self.roadClassMinimumZoom(cls) else {
            return hiddenStyle
        }
        // Road widths grow with zoom: hairlines at country/regional zooms, full
        // width at street level. Base widths below are the z14+ (full) values.
        let s = roadWidthScale(tileZoom: tileZoom)

        switch cls {
        case "motorway":
            return roadStyle(fillKey: 56, color: roads.motorway, width: 16 * s, priority: 95, casing: true, tunnel: isTunnel)
        case "trunk":
            return roadStyle(fillKey: 54, color: roads.trunk, width: 14 * s, priority: 90, casing: true, tunnel: isTunnel)
        case "primary":
            return roadStyle(fillKey: 52, color: roads.primary, width: 12 * s, priority: 80, casing: true, tunnel: isTunnel)
        case "secondary":
            return roadStyle(fillKey: 50, color: roads.secondary, width: 10 * s, priority: 78, casing: true, tunnel: isTunnel)
        case "tertiary":
            return roadStyle(fillKey: 48, color: roads.tertiary, width: 8 * s, priority: 74, casing: true, tunnel: isTunnel)
        case "minor":
            return roadStyle(fillKey: 44, color: roads.minor, width: 7.6 * s, priority: 50, casing: tileZoom >= 13, tunnel: isTunnel)
        case "service":
            return roadStyle(fillKey: 42, color: roads.service, width: 5.6 * s, priority: 45, casing: tileZoom >= 14, tunnel: isTunnel)
        case "path", "track":
            // Park alleys and walkways (footway/path/track): a thin solid
            // line, no dashes, which used to read as noise over water/parks.
            return roadStyle(fillKey: 40, color: roads.path, width: 3.2 * s, priority: 35, casing: false, tunnel: isTunnel)
        case "rail", "transit":
            return railStyle(subclass: subclass, tileZoom: tileZoom)
        case "ferry":
            return line(key: 41, color: configuration.layers.water, width: 4 * s, dashLength: 8, dashGap: 8)
        default:
            return roadStyle(fillKey: 43, color: roads.minor, width: 6.0 * s, priority: 40, casing: tileZoom >= 13, tunnel: isTunnel)
        }
    }

    /// The tile zoom a road class first draws at. Majors carry a country
    /// view; the minor network only means something near street level. The
    /// OpenMapTiles source ships most classes far earlier than they can read.
    private static func roadClassMinimumZoom(_ cls: String?) -> Int {
        switch cls {
        case "motorway", "trunk":
            return 0
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

    private func roadStyle(fillKey: UInt8,
                           color: SIMD4<Float>,
                           width: Double,
                           priority: Int,
                           casing: Bool,
                           tunnel: Bool) -> FeatureStyle {
        let fillGeometry = tunnel
            ? makeDashedRoadGeometry(width: width, dashLength: width * 2.0, dashGap: width * 1.2)
            : makeRoadGeometry(width: width)

        var passes: [LineRenderPass] = []
        if casing, tunnel == false {
            passes.append(
                LineRenderPass(key: Self.roadCasingKey(forFillKey: fillKey),
                               color: roadCasingColor(from: color),
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: makeRoadGeometry(width: width * 1.5),
                               includeRoadLabelPath: false,
                               roadPassRole: .casing)
            )
        }
        passes.append(
            LineRenderPass(key: fillKey,
                           color: color,
                           lowZoomFadeMask: roadLowZoomFadeMask,
                           parseGeometryStyleData: fillGeometry,
                           includeRoadLabelPath: false,
                           roadPassRole: .fill)
        )

        return FeatureStyle(
            key: fillKey,
            color: color,
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
            parseGeometryStyleData: makeDashedRoadGeometry(width: 4.0 * s, dashLength: 8, dashGap: 8),
            roadClassPriority: 30
        )
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

    private func boundaryStyle(props: [String: VectorTile_Tile.Value], tileZoom: Int) -> FeatureStyle {
        let adminLevel = parseIntValue(props["admin_level"]) ?? 4
        guard adminLevel <= 4 else {
            return hiddenStyle
        }
        if adminLevel > 2, tileZoom < Self.regionalBoundaryMinimumZoom {
            return hiddenStyle
        }
        // Borders are fully point-locked: the visible width comes from
        // lineWidthPoints (thinned toward planet zooms by LineWidthZoomTaper)
        // and the dash pattern from dash/gap points, stated in layout points
        // and anchored to the geometry at the tile's nominal display scale,
        // so neither is an accident of the tile grid. The geometry is a
        // continuous solid ribbon carrying arc length; the tessellated width
        // below is only the ceiling the shader can place the edge inside, at
        // full width at every zoom so it never undercuts the requested
        // points.
        let width: Double = adminLevel <= 2 ? 7.8 : 3.4
        let key: UInt8 = adminLevel <= 2 ? 102 : 100
        return FeatureStyle(
            key: key,
            color: configuration.layers.boundary,
            lowZoomFadeMask: 1.0,
            lineWidthPoints: adminLevel <= 2 ? 1.4 : 0.8,
            dashLengthPoints: 7.0,
            dashGapPoints: 3.5,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: width),
            // Borders are drawn as lines only. Some features (Native American
            // reservations) arrive as polygons; their area must not be filled,
            // otherwise you get solid purple blobs.
            suppressPolygonFill: true
        )
    }

    // MARK: - Labels

    private func placeLabelStyle(props: [String: VectorTile_Tile.Value]) -> FeatureStyle {
        let cls = props["class"]?.stringValue.lowercased()
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
        if isCapital(props) {
            appearance.sizePoints += 1.5
            appearance.weight = .bold
        }
        return pointLabel(key: 70, appearance: appearance)
    }

    private func waterLabelStyle(props: [String: VectorTile_Tile.Value]) -> FeatureStyle {
        var appearance = configuration.labels.water
        switch props["class"]?.stringValue.lowercased() {
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
    private func poiLabelStyle(props: [String: VectorTile_Tile.Value], tileZoom: Int) -> FeatureStyle {
        // POI appearance is derived from budget and priorities, with no
        // absolute zoom ramps: a label is visible once its effective rank fits
        // the grid-cell budget, and the budget quadruples with each zoom of
        // overzoom, exactly like the tile's screen area. The decision collapses
        // into a static threshold minCameraZoom = tile.z + log4(effRank / budget),
        // which the runtime and collisions apply by camera zoom. Classes define
        // a priority offset in rank units rather than zooms, so the approach
        // does not depend on the source maxzoom: switching sources shifts the
        // thresholds automatically via tile.z.
        let cls = props["class"]?.stringValue.lowercased()
        let subclass = props["subclass"]?.stringValue.lowercased()
        let rank = Double(parseIntValue(props["rank"]) ?? Self.poiDefaultRank)
        let effectiveRank = max(Self.poiNativeCellBudget,
                                rank + Self.poiClassRankBias(cls: cls, subclass: subclass))
        var minCameraZoom = Float(tileZoom)
            + Float(log2(effectiveRank / Self.poiNativeCellBudget) / 2.0)
        let isIconless = poiSpriteResolver.resolve(attributes: props, layerName: "poi") == nil
        if isIconless {
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

    /// Rank for features without a rank attribute: middle of the tail.
    private static let poiDefaultRank = 15

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

    private func polygon(key: UInt8, color: SIMD4<Float>) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    private func line(key: UInt8,
                      color: SIMD4<Float>,
                      width: Double,
                      dashLength: Double = 0,
                      dashGap: Double = 0) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
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
    private func roadCasingColor(from fill: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(fill.x - 0.20, 0.0),
                     max(fill.y - 0.20, 0.0),
                     max(fill.z - 0.20, 0.0),
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

    private func isCapital(_ props: [String: VectorTile_Tile.Value]) -> Bool {
        if let capital = parseIntValue(props["capital"]), capital > 0 {
            return true
        }
        return false
    }

    private func parseIntValue(_ value: VectorTile_Tile.Value?) -> Int? {
        guard let value else {
            return nil
        }
        if value.hasIntValue {
            return Int(value.intValue)
        }
        if value.hasUintValue {
            return Int(value.uintValue)
        }
        if value.hasSintValue {
            return Int(value.sintValue)
        }
        if value.hasDoubleValue {
            return Int(value.doubleValue)
        }
        if value.hasFloatValue {
            return Int(value.floatValue)
        }
        if value.hasStringValue {
            return Int(value.stringValue.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
