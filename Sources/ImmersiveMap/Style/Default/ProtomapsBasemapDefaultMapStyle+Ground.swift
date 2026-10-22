// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The ground: the land cover of the overview zooms, the land use of the
/// street zooms, the rivers and the administrative boundaries drawn on it.
///
/// Polygon draw order is by ascending key. The built-up tints
/// (residential, industrial) are lowered to key 9 while all greenery goes
/// above them (11-18), otherwise a park lying inside a residential polygon
/// would be covered and look like bare ground. Greenery stays below water
/// (key 30) and roads. Each colour gets its own key (the first-wins
/// `styles[key]` would otherwise collapse every fill of a tile into the
/// first polygon's colour, producing seams at tile borders).
///
/// At the overview zooms (through `BiomeStyles.maximumTileZoom`) the
/// engine's overview lays its biomes into the tiles (`OverviewTileSource`)
/// and the biomes paint the land in place of the land cover and the land
/// use, which take the keys the hidden fills leave free, 3 to 7, 9, 11 to
/// 16, 18 and 19, one per biome as above: a tile carries either the biomes
/// or the land cover, never both, and the rules read the one zoom
/// (`overviewPaintsLand`). Over the biomes, from
/// `BiomeStyles.coverMinimumTileZoom`, the tiles' own land cover draws its
/// forests, fields, bare ground, ice and cities in the block 20 to 24 and
/// the land use its woods, fields, bare ground, wetlands and ice in the
/// block 25 to 29, both under the water: what the biomes say of the
/// climate, the cover says of the ground, and the holes between the
/// raster-derived blobs show the biome instead of bare land. The two
/// blocks part at the end of the overview: the biomes and the land cover
/// fade out over camera zoom 7 to 8, the land use, the same OSM polygons
/// the z8 tiles carry, stays.
extension ProtomapsBasemapDefaultMapStyle {
    /// The water fill's key: over every painted ground, under the
    /// waterway lines, the ferries and the bridge decks.
    static let waterKey: UInt8 = 30

    /// Whether the tile's land cover and land use give way to the
    /// overview's biomes: the tile zooms through
    /// `BiomeStyles.maximumTileZoom`, where the overview lays its biomes
    /// into the tiles (`OverviewTileSource`). The overview is laid in by a
    /// setting (`TileSettings.OverviewSettings`), and a map that has it off
    /// shows the land cover at these zooms the way it did before: the
    /// style cannot see the setting, so the land cover rules take the same
    /// turn whether the biomes arrived or not, and with the overview off
    /// the land under the hidden cover is the earth polygon's land tone.
    func overviewPaintsLand(tileZoom: Int) -> Bool {
        tileZoom <= theme.layers.biomes.maximumTileZoom
    }

    /// Whether the overview's road network stands in for the tiles' own
    /// roads at a tile zoom (`OverviewRoadStyles.maximumTileZoom`): through
    /// it the Natural Earth network draws and the basemap's roads, the
    /// motorways alone at those zooms, are hidden.
    func overviewRoadNetworkDraws(tileZoom: Int) -> Bool {
        overviewPaintsLand(tileZoom: tileZoom) && tileZoom <= theme.layers.overviewRoads.maximumTileZoom
    }

    /// The overview's `road` layer: the Natural Earth network, one stroke
    /// per road in points, the main roads by rank in the theme's highway
    /// yellow and the rest thinner and paler, round-joined like the
    /// basemap's overview strokes and under the same veil on the globe
    /// (`RoadMetrics.globeOpacity`). A ground line among the ground lines,
    /// the main roads over the minor ones, both under the borders.
    func overviewRoadNetworkStyle(rank: Int?, tileZoom: Int) -> FeatureStyle {
        guard overviewRoadNetworkDraws(tileZoom: tileZoom) else {
            return hiddenStyle
        }
        let network = theme.layers.overviewRoads
        let isMajor = (rank ?? Int.max) <= network.majorMaximumRank
        let widthPoints = isMajor ? network.majorWidthPoints : network.minorWidthPoints
        let pass = LinePass(key: isMajor ? 45 : 44,
                            color: isMajor ? network.major : network.minor,
                            zoomFade: Self.roadZoomFade,
                            lineWidthPoints: widthPoints,
                            sphereAlpha: theme.roadMetrics.globeOpacity,
                            sphereColor: globeColor { isMajor ? $0.overviewRoads.major : $0.overviewRoads.minor },
                            lineGeometry: LineGeometryStyle(
                                lineWidth: Double(widthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint,
                                lineCapRound: true,
                                lineJoinRound: true))
        return .line(LineStyle(pass: pass, fillsAreas: false))
    }

    /// The overview's `biome`: one fill per biome, each in the atlas tone
    /// the theme gives it (`BiomeStyles`), on the tiles of the overview
    /// zooms and hidden past them, where the land is the earth polygon
    /// under the land use. The biomes tile the land without overlapping,
    /// so their order among themselves is nothing. A kind the style does
    /// not name draws in the temperate grassland tone rather than not at
    /// all. The biomes fade out with the land cover over camera zoom 7 to
    /// 8 (`landcoverZoomFade`), so the z7 tiles, the last to carry them,
    /// hand the land tone to the z8 tiles with the camera.
    func biomeStyle(kind: String?, tileZoom: Int) -> FeatureStyle {
        guard overviewPaintsLand(tileZoom: tileZoom) else {
            return hiddenStyle
        }
        let key: UInt8
        let tone: KeyPath<ProtomapsBasemapTheme.BiomeStyles, SIMD4<Float>>
        switch kind {
        case "tundra": (key, tone) = (3, \.tundra)
        case "desert": (key, tone) = (4, \.desert)
        case "montane_grassland": (key, tone) = (6, \.montaneGrassland)
        case "tropical_grassland": (key, tone) = (7, \.tropicalGrassland)
        case "mediterranean_scrub": (key, tone) = (9, \.mediterraneanScrub)
        case "flooded_grassland": (key, tone) = (11, \.floodedGrassland)
        case "mangrove": (key, tone) = (12, \.mangrove)
        case "boreal_forest": (key, tone) = (13, \.borealForest)
        case "temperate_conifer_forest": (key, tone) = (14, \.temperateConiferForest)
        case "temperate_broadleaf_forest": (key, tone) = (15, \.temperateBroadleafForest)
        case "tropical_conifer_forest": (key, tone) = (16, \.tropicalConiferForest)
        case "tropical_dry_forest": (key, tone) = (18, \.tropicalDryForest)
        case "tropical_moist_forest": (key, tone) = (19, \.tropicalMoistForest)
        default: (key, tone) = (5, \.temperateGrassland)
        }
        return polygon(key: key, colorOf: { $0.biomes[keyPath: tone] }, zoomFade: Self.landcoverZoomFade)
    }

    /// The overview's `lake`, the lakes of tile zoom 0, where the basemap
    /// ships none: the water fill, under the same key as the basemap's.
    func overviewLakeStyle(tileZoom: Int) -> FeatureStyle {
        guard overviewPaintsLand(tileZoom: tileZoom) else {
            return hiddenStyle
        }
        return polygon(key: Self.waterKey, colorOf: \.water)
    }

    /// The basemap's `landcover`: the continuous Daylight land cover it
    /// ships through z7, raster-derived blobs whose classes blend toward
    /// one shared tone over the globe and release to the unmixed palette
    /// by the country zooms. Each class wears the colour of what replaces
    /// it from z8 (a landcover forest the wood, farmland the farmland,
    /// barren the sand, a glacier the ice), so the swap changes the
    /// geometry source and never the colour. Grassland and scrub have no
    /// land use counterpart: from z8 open country is the bare `earth`
    /// polygon, so they release to the land tone. Painting them in the
    /// full grass green turned every z7 plain green and the step to z8
    /// into a jump from green to cream.
    ///
    /// The land cover draws on every tile that ships it, under the land
    /// use of the same tile, and a class the style does not name draws in
    /// the grassland tone rather than not at all. It fades out over camera
    /// zoom 7 to 8 (`landcoverZoomFade`), while the z7 tiles, the last to
    /// carry it, still serve the view, so it leaves with the camera instead
    /// of popping off with the tile level.
    func landcoverStyle(kind: String?, tileZoom: Int) -> FeatureStyle {
        let colors = theme.layers
        let fade = Self.landcoverZoomFade
        if overviewPaintsLand(tileZoom: tileZoom) {
            // The biomes paint the land. On the globe (under
            // `coverMinimumTileZoom`) the raster-derived classes give way
            // to them whole, but the ice, which the biomes do not paint,
            // stays over every biome, and the cities stay, the one thing a
            // region view exists to show. From the cover zoom the forests,
            // the fields and the bare ground draw over the biomes in the
            // cover tones, a step off the biomes', and their holes show
            // the biome. Grassland and scrub never draw: the biome is
            // their tone. (Painted in the fields' tone the grassland filled
            // the holes between the fields and took the biome's tone out of
            // the temperate zone, two tones where three read better, and
            // the woods got no finer for it.) One key per cover tone, the
            // land use of the same ground in its own block over this one
            // (`landuseStyle`): the land cover leaves with the biomes, the
            // land use does not, so they cannot share a fill.
            let biomes = colors.biomes
            let coverDrawn = tileZoom >= biomes.coverMinimumTileZoom
            switch kind {
            case "forest" where coverDrawn:
                return polygon(key: 20, colorOf: \.biomes.forestCover, zoomFade: fade)
            case "farmland" where coverDrawn:
                return polygon(key: 21, colorOf: \.biomes.farmlandCover, zoomFade: fade)
            case "barren" where coverDrawn:
                return polygon(key: 22, colorOf: \.biomes.barrenCover, zoomFade: fade)
            case "glacier":
                return polygon(key: 23, colorOf: \.ice, zoomFade: fade)
            case "urban_area":
                return polygon(key: 24, colorOf: \.residential, zoomFade: fade)
            default:
                return hiddenStyle
            }
        }
        let amount = Self.vegetationBlendAmount(tileZoom: tileZoom)
        switch kind {
        case "barren":
            return polygon(key: 3, colorOf: \.sand, zoomFade: fade)
        case "grassland", "scrub", nil:
            return polygon(key: 4,
                           colorOf: { self.blend($0.land, toward: $0.grass, amount: amount) },
                           zoomFade: fade)
        case "farmland":
            return polygon(key: 5,
                           colorOf: { self.blend($0.farmland, toward: $0.grass, amount: amount) },
                           zoomFade: fade)
        case "forest":
            return polygon(key: 6,
                           colorOf: { self.blend($0.wood, toward: $0.grass, amount: amount * 0.75) },
                           zoomFade: fade)
        case "glacier":
            return polygon(key: 8, colorOf: \.ice, zoomFade: fade)
        case "urban_area":
            // Cities are the one thing a region view exists to show: the
            // residential tone, clearly apart from the greens, the same the
            // street map's residential land use wears from z8.
            return polygon(key: 10, colorOf: \.residential, zoomFade: fade)
        default:
            return landcoverStyle(kind: nil, tileZoom: tileZoom)
        }
    }

    /// How far the vegetation classes blend toward the shared tone at a tile
    /// zoom: 1 is the full massive-overview merge, 0 the unmixed palette.
    static func vegetationBlendAmount(tileZoom: Int) -> Float {
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

    func blend(_ base: SIMD4<Float>,
               toward target: SIMD4<Float>,
               amount: Float) -> SIMD4<Float> {
        base + (target - base) * amount
    }

    /// The basemap's `landuse`: the OSM land use and the natural cover,
    /// one kind per feature, on every tile that ships it. It lies over the
    /// land cover of the coarse tiles that carry both. A kind the style
    /// does not name draws in the muted built tone rather than not at all.
    func landuseStyle(kind: String?, tileZoom: Int) -> FeatureStyle {
        let colors = theme.layers
        let fade = ImmersiveMapZoomFade.none
        if overviewPaintsLand(tileZoom: tileZoom) {
            // The biomes paint the land, and the land use draws over them
            // what the land cover does, in the cover tones, in its own
            // block of keys over the land cover's: the woods, the fields,
            // the bare ground, the wetlands and the ice, from the cover
            // zoom, the ice alone before it. The parks, the reserves and
            // the built ground of the coarse tiles are hidden: they would
            // lie as blotches on the painting. The land use does not fade:
            // it is the same OSM polygons the z8 tiles carry, so while the
            // biomes and the raster-derived land cover fade out under it
            // over camera zoom 7 to 8, the woods and the fields stand
            // through to the street map and the z8 tiles take them over in
            // place, with no cover to appear from nowhere.
            let biomes = colors.biomes
            guard tileZoom >= biomes.coverMinimumTileZoom else {
                return kind == "glacier" ? polygon(key: 29, colorOf: \.ice) : hiddenStyle
            }
            switch kind {
            case "forest", "wood":
                return polygon(key: 25, colorOf: \.biomes.forestCover)
            case "farmland", "orchard", "allotments", "vineyard", "plant_nursery":
                return polygon(key: 26, colorOf: \.biomes.farmlandCover)
            case "sand", "beach", "bare_rock", "quarry", "scree", "shingle":
                return polygon(key: 27, colorOf: \.biomes.barrenCover)
            case "wetland":
                return polygon(key: 28, colorOf: \.wetland)
            case "glacier":
                return polygon(key: 29, colorOf: \.ice)
            default:
                return hiddenStyle
            }
        }
        switch kind {
        case "residential", "neighbourhood", "farmyard":
            return polygon(key: 9, colorOf: \.residential, zoomFade: fade)
        case "protected_area":
            // A protected area blankets whole regions and city centres: a
            // faint green over the land, under the built-up tints and every
            // other fill, so it shows only where nothing else is.
            return polygon(key: 7, colorOf: { self.blend($0.land, toward: $0.grass, amount: 0.25) }, zoomFade: fade)
        case "commercial", "industrial", "railway", "military",
             "hospital", "school", "university", "college":
            // Schools and hospitals are the muted built tone, not a green:
            // their grounds are courtyards and car parks, not parks.
            return polygon(key: 9, colorOf: \.industrial, zoomFade: fade)
        case "forest", "wood":
            return polygon(key: 11, colorOf: \.wood, zoomFade: fade)
        case "park", "garden", "grass", "meadow", "recreation_ground", "cemetery",
             "golf_course", "pitch", "playground", "dog_park", "zoo",
             "national_park", "nature_reserve", "scrub", "grassland", "heath",
             "village_green", "camp_site", "picnic_site":
            // One green for all urban greenery, so no two-tone seam where a
            // park meets the pitch inside it.
            return polygon(key: 12, colorOf: \.grass, zoomFade: fade)
        case "farmland", "orchard", "allotments", "vineyard", "plant_nursery":
            return polygon(key: 13, colorOf: \.farmland, zoomFade: fade)
        case "wetland":
            return polygon(key: 14, colorOf: \.wetland, zoomFade: fade)
        case "glacier":
            return polygon(key: 17, colorOf: \.ice, zoomFade: fade)
        case "sand", "beach", "bare_rock", "quarry", "scree", "shingle":
            return polygon(key: 18, colorOf: \.sand, zoomFade: fade)
        case "aerodrome", "airfield", "runway", "taxiway", "apron", "helipad":
            return polygon(key: 19, colorOf: \.aeroway, zoomFade: fade)
        case "pedestrian", "pier":
            // The basemap ships a bridge's deck (`man_made=bridge`) as a
            // `pedestrian` area, the same kind as a paved square. The deck
            // lies over the river, so it draws above the water, its
            // waterway lines and the ferry routes, in the land tone, under
            // the roads it carries. A square on land in the land tone reads
            // as the ground it is.
            return .fill(FillStyle(key: Self.bridgeDeckKey,
                                   color: colors.land,
                                   drawsAmongGroundLines: true,
                                   sphereColor: globeColor(\.land)))
        default:
            // Everything else the basemap ships (retail, construction, a
            // platform, a kindergarten, a stadium, a marina, `other`) is
            // built or managed ground: the muted built tone marks where it
            // is without a colour of its own.
            return polygon(key: 9, colorOf: \.industrial, zoomFade: fade)
        }
    }

    /// The deck's place among the ground lines: above the waterway lines
    /// (31 and 32) and the ferry routes (33), below the aeroway lines and
    /// the borders.
    static let bridgeDeckKey: UInt8 = 34

    /// A river, a canal or a stream: the lines of the `water` layer. The
    /// basemap spells the waterway kind on `kind` for a line and on
    /// `kind_detail` for a body, so both are read.
    ///
    /// A culverted waterway (a negative `layer`, or a `tunnel` tag) still
    /// draws, at the tunnel opacity of a road, so the network stays joined
    /// and reads as underground.
    func waterwayStyle(kind: String?, kindDetail: String?, props: [String: MvtValue]) -> FeatureStyle {
        let tunnelTag = props["tunnel"]?.stringValue?.lowercased()
        let isCulvert = (parseIntValue(props["layer"]) ?? 0) < 0
            || (tunnelTag.map { $0.isEmpty == false && $0 != "no" } ?? false)
        // The basemap ships major rivers from z9; without a floor their
        // 2.5-unit width is sub-pixel over a region view and the
        // antialiasing correctly dims them to near-invisibility, so a point
        // floor keeps them readable threads from the first tile they appear
        // in. World growth takes over at street zoom as with roads.
        let width: Double
        let minimumWidthPoints: Float
        switch kindDetail ?? kind {
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
        let tone: (ProtomapsBasemapTheme.LayerStyles) -> SIMD4<Float> = { isCulvert ? Self.tunnelTone($0.water) : $0.water }
        return line(key: isCulvert ? 31 : 32,
                    color: tone(theme.layers),
                    width: width,
                    minimumWidthPoints: minimumWidthPoints,
                    sphereColor: globeColor(tone))
    }

    /// The `boundaries` layer: every level the tile ships. A national
    /// border is the one solid line, the convention of the atlas: the
    /// regions and the finer levels (a county, a municipality, a map unit)
    /// draw dashed, thinner and lighter, and a line the basemap marks as
    /// no recognised border (a disputed claim, an unrecognised country,
    /// the limit of a sea overlay) takes the short dash of a disputed
    /// border.
    func boundaryStyle(kind: String?, props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        enum Level { case country, region, local }
        let level: Level
        var disputed = parseBoolValue(props["disputed"])
        switch kind {
        case "country":
            level = .country
        case "unrecognized_country", "disputed":
            level = .country
            disputed = true
        case "region", "map_unit":
            level = .region
        case "overlay_limit":
            level = .local
            disputed = true
        default:
            level = .local
        }
        // Borders draw through the point-locked line factory (see
        // FeatureStyle.pointLockedLine, which documents the principle they
        // originated): width and dash pattern in layout points, opaque, butt
        // ends, ribbon provisioned to host the width. One key per colour.
        let key: UInt8
        let widthPoints: Float
        // The softening of the palette's boundary tone, the same over the
        // plane's palette and the globe's.
        let towardWhite: Float
        let alpha: Float
        switch level {
        case .country:
            key = 103
            widthPoints = 1.0
            // A national border is a reference line, not the subject of
            // the map: it draws through the fills, half transparent, and
            // over a country or the globe it lightens a little. Still the
            // strongest line of the family at every zoom, so it stands
            // apart from the regional borders by colour as well as by
            // being the one solid line among them.
            (towardWhite, alpha) = tileZoom <= 6 ? (0.15, 0.55) : (0, 0.65)
        case .region:
            key = 100
            widthPoints = 1.1
            // Regional borders are a step lighter and more transparent
            // than the national ones at every zoom, and over a country or
            // the globe, where the lines are the one cold hue in the frame
            // and a full purple reads as scribble, they lighten further.
            (towardWhite, alpha) = tileZoom <= 6 ? (0.45, 0.45) : (0.2, 0.6)
        case .local:
            key = 98
            widthPoints = 0.7
            (towardWhite, alpha) = (0.45, 0.55)
        }
        let tone: (ProtomapsBasemapTheme.LayerStyles) -> SIMD4<Float> = {
            Self.softenedBoundaryColor($0.boundary, towardWhite: towardWhite, alpha: alpha)
        }
        // Borders are drawn as lines only: the point-locked mode fills no
        // areas, so a boundary that arrives as a polygon is never a blob.
        // The dash is part of the baked style, so a disputed line takes
        // the key under its level's. A recognised national border is
        // solid, the regions and below dash.
        let dashLengthPoints: Float
        let dashGapPoints: Float
        if disputed {
            (dashLengthPoints, dashGapPoints) = (3.0, 3.0)
        } else if level == .country {
            (dashLengthPoints, dashGapPoints) = (0, 0)
        } else {
            (dashLengthPoints, dashGapPoints) = (7.0, 3.5)
        }
        return FeatureStyle.pointLockedLine(
            key: disputed ? key - 1 : key,
            color: tone(theme.layers),
            widthPoints: widthPoints,
            dashLengthPoints: dashLengthPoints,
            dashGapPoints: dashGapPoints,
            sphereColor: globeColor(tone)
        )
    }

    static func softenedBoundaryColor(_ color: SIMD4<Float>, towardWhite amount: Float, alpha: Float) -> SIMD4<Float> {
        let softened = color + (SIMD4<Float>(1, 1, 1, color.w) - color) * amount
        return SIMD4<Float>(softened.x, softened.y, softened.z, color.w * alpha)
    }
}
