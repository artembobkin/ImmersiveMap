// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The look of the built-in style (the Protomaps basemap) as plain values:
/// the colour of every layer and road class, the building fill, the label
/// appearances and which labels show, and the route signs. An app recolours the map by changing a field of the default
/// and never touches the layer logic:
///
/// ```swift
/// ImmersiveMapView()
///     .mapStyle(.default.apply { theme in
///         theme.layers.water = [0.2, 0.4, 0.8, 1]
///         theme.layers.roads.motorway = [0.95, 0.6, 0.2, 1]
///     })
/// ```
///
/// Colours are RGBA in 0...1. Every value feeds the cache fingerprint, so a
/// change rebakes the prepared tiles by itself, but the hillshade, which is
/// drawn at frame time and baked into nothing.
public struct ProtomapsBasemapTheme: Equatable, Sendable {
    public struct LabelAppearance: Equatable, Sendable {
        public var fillColor: SIMD3<Float>
        public var strokeColor: SIMD3<Float>
        /// Halo width as a fraction of the em, so it tracks the text size.
        public var haloEm: Float
        /// Em size in layout points, not device pixels: the engine multiplies by
        /// the display's pixels-per-point at render time, so a value here reads
        /// at the same physical size on a 2x desktop display and a 3x phone.
        public var sizePoints: Float
        public var weight: LabelFontWeight
        /// Whether the label is set in capitals.
        public var uppercased: Bool
        /// How far the letters are grown past the font's outline, in layout
        /// points (`LabelTextStyle.emboldenPoints`).
        public var emboldenPoints: Float
        /// Extra room after every letter, in ems
        /// (`LabelTextStyle.letterSpacingEm`): the tracking of a name spaced
        /// out over the land it names.
        public var letterSpacingEm: Float
        /// The opacity of the label, fill and halo alike
        /// (`LabelTextStyle.opacity`): 1 solid, less lets the map show
        /// through a name laid over it.
        public var opacity: Float

        public init(fillColor: SIMD3<Float>,
                    strokeColor: SIMD3<Float>,
                    haloEm: Float,
                    sizePoints: Float,
                    weight: LabelFontWeight,
                    uppercased: Bool = false,
                    emboldenPoints: Float = LabelTextStyle.defaultEmboldenPoints,
                    letterSpacingEm: Float = 0,
                    opacity: Float = 1) {
            self.fillColor = fillColor
            self.strokeColor = strokeColor
            self.haloEm = haloEm
            self.sizePoints = sizePoints
            self.weight = weight
            self.uppercased = uppercased
            self.emboldenPoints = emboldenPoints
            self.letterSpacingEm = letterSpacingEm
            self.opacity = opacity
        }
    }

    public struct LabelStyles: Equatable, Sendable {
        public var city: LabelAppearance
        public var town: LabelAppearance
        /// The districts of a city: its neighbourhoods and the larger
        /// quarters they make up, and the places smaller than a town (a
        /// village, a hamlet, a named square).
        public var district: LabelAppearance
        /// A country's name: the name of a land, not of a point, so by
        /// default it is set apart from the places in it, in spaced
        /// capitals above every city's size.
        public var country: LabelAppearance
        /// A region's name (a state, a province, a land): under the
        /// country's, in the same manner, above a city's.
        public var region: LabelAppearance
        public var poi: LabelAppearance
        public var water: LabelAppearance
        public var road: LabelAppearance

        public init(city: LabelAppearance,
                    town: LabelAppearance,
                    district: LabelAppearance = LabelStyles.default.district,
                    country: LabelAppearance,
                    region: LabelAppearance = LabelStyles.default.region,
                    poi: LabelAppearance,
                    water: LabelAppearance,
                    road: LabelAppearance) {
            self.city = city
            self.town = town
            self.district = district
            self.country = country
            self.region = region
            self.poi = poi
            self.water = water
            self.road = road
        }
    }

    /// Zoom thresholds that decide whether a label class is drawn at all (as
    /// opposed to `LabelStyles`, which only decides how a drawn label looks).
    ///
    /// The default is a density curve, not a filter: a city centre reads at
    /// every zoom instead of drowning in names. A POI shows from the zoom the
    /// basemap ranks it at (its `min_zoom`), so the landmarks, the parks and
    /// the metro lead at z13 and z14, and the restaurants, cafés and shops
    /// come in at z16 and z17. On top of that, the categories that help only
    /// someone standing in the street (post offices, cash machines, clinics,
    /// schools, stops and entrances, parking, named plots without a symbol)
    /// wait for the street zooms, and so do the house numbers and the
    /// longest names.
    public struct LabelVisibility: Equatable, Sendable {
        /// The zoom a POI category waits for, whatever the basemap ranks
        /// the POI at. The categories not named here follow the basemap
        /// alone.
        public struct PoiCategoryZooms: Equatable, Sendable {
            /// Universities, colleges and institutes: many, large and named
            /// at length, so they would crowd out the landmarks at z13.
            public var campus: Int
            /// Shops, other than malls, department stores and markets.
            public var shop: Int
            /// The street-level services: post and parcel offices, banks and
            /// cash machines, pharmacies, clinics and doctors, schools and
            /// kindergartens, offices of the state, embassies, police and
            /// fire stations, public toilets, fuel and charging.
            public var service: Int
            /// The pieces of transit: stops, platforms, metro entrances,
            /// taxi ranks, parking and bike docks. The stations themselves
            /// follow the basemap.
            public var transitDetail: Int

            public init(campus: Int = 14,
                        shop: Int = 16,
                        service: Int = 17,
                        transitDetail: Int = 17) {
                self.campus = campus
                self.shop = shop
                self.service = service
                self.transitDetail = transitDetail
            }
        }

        /// Whether a POI needs an icon to be labelled at all.
        ///
        /// A category the icon set does not recognize (an office, a company, a
        /// monument, a named building) has nothing to draw but its name, and
        /// those names are the bulk of a city centre's POIs: bare text over the
        /// buildings, in the type size of a landmark, saying nothing about what
        /// the place is. The default draws their names alone, without an
        /// icon, from `poiIconlessMinimumZoom` on. Set to `true` to leave them
        /// out altogether.
        public var poiRequiresIcon: Bool

        /// Minimum camera zoom from which icon-less POIs (offices, companies, and
        /// other categories outside the set of recognized icons) are drawn. POIs
        /// with an icon draw from the regular threshold, so overview zooms keep
        /// only icon POIs while the dense scatter of text-only labels kicks in
        /// deeper. Read only when `poiRequiresIcon` is `false`, since otherwise
        /// icon-less POIs are not drawn at any zoom.
        public var poiIconlessMinimumZoom: Int

        /// Minimum camera zoom from which any POI label (icon or icon-less) is
        /// drawn, applied on top of the rank-derived thresholds. The default 0
        /// keeps the rank behavior; a value above the camera's maximum zoom
        /// hides POIs entirely (useful for clean cinematic footage).
        public var poiMinimumZoom: Int

        /// Whether a POI waits for the zoom the basemap ranks it at, its
        /// `min_zoom`. Off, every POI a tile ships competes from the tile's
        /// own zoom, and only the collisions thin them out.
        public var poiFollowsSourceMinimumZoom: Bool

        /// The zooms whole POI categories wait for.
        public var poiCategoryMinimumZoom: PoiCategoryZooms

        /// A POI whose name runs past `poiLongNameCharacterCount` characters
        /// waits for this zoom: a name that wraps to three lines is a block of
        /// text, not a label, until the map has room for it.
        public var poiLongNameMinimumZoom: Int
        public var poiLongNameCharacterCount: Int

        /// Minimum camera zoom of the house numbers.
        public var addressMinimumZoom: Int

        /// The camera zoom a country's name goes away at: shown below it,
        /// hidden from it on. The basemap ships the names of the countries
        /// into the street zooms, where a name that stands for the whole
        /// land reads as one more town among the towns. The default keeps
        /// it to the views that hold a country, up to zoom 7.
        public var countryMaximumZoom: Int
        /// The camera zoom a region's name goes away at, as
        /// `countryMaximumZoom`: a state or a province is read a couple of
        /// zooms deeper than its country.
        public var regionMaximumZoom: Int

        /// Whether the local detail, the icon-less POIs (a memorial, an
        /// office, a ticket window) and the house numbers, shows only near
        /// the camera (`PointLabelStyle.isLocal`): in the three by three
        /// tiles around the look-at tile, and there within
        /// `BaseSettings.localDetailMaximumDistanceMeters` of the camera.
        /// They are what one reads standing next to them, and on a tilted
        /// map the street beyond would fill with small text saying nothing
        /// at that distance.
        /// Off, they show wherever their zoom lets them. Baked into the
        /// prepared tiles, so a change re-parses them.
        public var localDetailInLookAtTileOnly: Bool

        public init(poiIconlessMinimumZoom: Int = 17,
                    poiMinimumZoom: Int = 0,
                    poiRequiresIcon: Bool = false,
                    poiFollowsSourceMinimumZoom: Bool = true,
                    poiCategoryMinimumZoom: PoiCategoryZooms = PoiCategoryZooms(),
                    poiLongNameMinimumZoom: Int = 17,
                    poiLongNameCharacterCount: Int = 32,
                    addressMinimumZoom: Int = 17,
                    countryMaximumZoom: Int = 8,
                    regionMaximumZoom: Int = 10,
                    localDetailInLookAtTileOnly: Bool = true) {
            self.poiIconlessMinimumZoom = poiIconlessMinimumZoom
            self.poiMinimumZoom = poiMinimumZoom
            self.poiRequiresIcon = poiRequiresIcon
            self.poiFollowsSourceMinimumZoom = poiFollowsSourceMinimumZoom
            self.poiCategoryMinimumZoom = poiCategoryMinimumZoom
            self.poiLongNameMinimumZoom = poiLongNameMinimumZoom
            self.poiLongNameCharacterCount = poiLongNameCharacterCount
            self.addressMinimumZoom = addressMinimumZoom
            self.countryMaximumZoom = countryMaximumZoom
            self.regionMaximumZoom = regionMaximumZoom
            self.localDetailInLookAtTileOnly = localDetailInLookAtTileOnly
        }
    }

    /// The road classes the style draws, the tiers it folds the Protomaps
    /// `roads` layer's `kind` and `kind_detail` into: a `highway` is a
    /// motorway, a `major_road` is a trunk, primary, secondary or tertiary
    /// by its detail, a `minor_road` is minor or service, a `path` is a
    /// path. `other` stands for every road the style draws without naming
    /// its class.
    public enum RoadClass: CaseIterable, Sendable {
        case motorway
        case trunk
        case primary
        case secondary
        case tertiary
        case minor
        case service
        case path
        case other
    }

    /// One colour per road class, plus the rail, the casing and the paint
    /// on the asphalt.
    public struct RoadLayerStyles: Equatable, Sendable {
        public var motorway: SIMD4<Float>
        public var trunk: SIMD4<Float>
        public var primary: SIMD4<Float>
        public var secondary: SIMD4<Float>
        public var tertiary: SIMD4<Float>
        public var minor: SIMD4<Float>
        public var service: SIMD4<Float>
        public var path: SIMD4<Float>
        public var rail: SIMD4<Float>
        public var casing: SIMD4<Float>
        /// The paint on the asphalt: the arrows of a one-way street. Fully
        /// opaque, since two overlapping quads of a translucent colour
        /// composite twice and stamp a denser patch.
        public var marking: SIMD4<Float>

        public init(motorway: SIMD4<Float>,
                    trunk: SIMD4<Float>,
                    primary: SIMD4<Float>,
                    secondary: SIMD4<Float>,
                    tertiary: SIMD4<Float>,
                    minor: SIMD4<Float>,
                    service: SIMD4<Float>,
                    path: SIMD4<Float>,
                    rail: SIMD4<Float>,
                    casing: SIMD4<Float>,
                    marking: SIMD4<Float> = RoadLayerStyles.defaultMarking) {
            self.motorway = motorway
            self.trunk = trunk
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
            self.minor = minor
            self.service = service
            self.path = path
            self.rail = rail
            self.casing = casing
            self.marking = marking
        }

        /// An off-white that reads on the asphalt grey without glaring.
        public static let defaultMarking = SIMD4<Float>(0.97, 0.97, 0.96, 1.0)
    }

    /// One value per road class (`RoadClass`), `other` standing for every
    /// road the style draws without naming its class.
    public struct RoadClassValues<Value: Equatable & Sendable>: Equatable, Sendable {
        public var motorway: Value
        public var trunk: Value
        public var primary: Value
        public var secondary: Value
        public var tertiary: Value
        public var minor: Value
        public var service: Value
        public var path: Value
        public var other: Value

        public init(motorway: Value,
                    trunk: Value,
                    primary: Value,
                    secondary: Value,
                    tertiary: Value,
                    minor: Value,
                    service: Value,
                    path: Value,
                    other: Value) {
            self.motorway = motorway
            self.trunk = trunk
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
            self.minor = minor
            self.service = service
            self.path = path
            self.other = other
        }

        /// The value of a road class.
        public func value(for roadClass: RoadClass) -> Value {
            switch roadClass {
            case .motorway: return motorway
            case .trunk: return trunk
            case .primary: return primary
            case .secondary: return secondary
            case .tertiary: return tertiary
            case .minor: return minor
            case .service: return service
            case .path: return path
            case .other: return other
            }
        }

        var all: [Value] {
            [motorway, trunk, primary, secondary, tertiary, minor, service, path, other]
        }
    }

    /// How wide the roads of the street era draw and from where, as opposed
    /// to `RoadLayerStyles`, which is only their colours.
    public struct RoadMetrics: Equatable, Sendable {
        /// The width of a class as a symbol, in points: what it draws at on
        /// screen from `symbolZoom` up to `worldLockZoom`.
        public var symbolWidthPoints: RoadClassValues<Float>

        /// The width of a class over a country view, in points: what it
        /// draws at up to `overviewZoom`. Between `overviewZoom` and
        /// `symbolZoom` the width grows from this to `symbolWidthPoints` by
        /// the same ratio per zoom level, continuous in camera zoom, so a
        /// road never steps in width, neither with the camera nor when the
        /// engine swaps the tile level serving it.
        public var overviewWidthPoints: RoadClassValues<Float>

        /// The camera zoom up to which a road is its overview stroke.
        public var overviewZoom: Float

        /// The camera zoom from which a road is its full symbol.
        public var symbolZoom: Float

        /// The opacity of the overview stroke. It grows to one along with
        /// the width, by `symbolZoom`. One by default: a road is opaque at
        /// every zoom, which is what lets the engine shade each of its
        /// pixels once, with no blending. Below one the stroke is a veil
        /// that lets the ground colours stay the picture over a country
        /// view, and the roads blend until `symbolZoom`.
        public var overviewOpacity: Float

        /// The opacity of the overview stroke on the globe, `0...1`: a veil
        /// the globe's view lays over the roads, so the painted ground
        /// stays the picture of a continent and the roads a net over it.
        /// 0.6 by default. One is the same stroke as on the plane. It holds
        /// through the globe's view and its unroll into the plane, is handed
        /// over with the globe's air at the end of the unroll
        /// (`PresentationSettings.airHandoverStart` to `airHandoverEnd`),
        /// and the plane never has it, whatever `overviewOpacity` says
        /// there. The engine blends each stroke once on the globe, so
        /// the veil never darkens where two strokes cross.
        public var globeOpacity: Float

        /// The camera zoom from which a road's width is fixed on the ground
        /// instead of on screen. Up to it a road is a symbol of
        /// `symbolWidthPoints`. Past it the road keeps the ground width the
        /// symbol had at this zoom, so it doubles on screen with every zoom
        /// level, like the blocks and the buildings around it, and never
        /// thins into a hairline at street level. The handover is continuous
        /// in camera zoom. Zero keeps every road a symbol at every zoom.
        public var worldLockZoom: Float

        /// Whether the automobile roads wear a casing: an outline a point
        /// wide on each side of a road's symbol that eases in at street
        /// zoom, and the kerb of a measured junction surface. Off by
        /// default: the roads read as one sheet of asphalt against the
        /// ground, and an outline around every street turns the sheet back
        /// into separate ribbons.
        public var drawsCasing: Bool

        /// The tile zoom a class first draws at. The style draws what the
        /// tiles carry from this zoom on. The default is 0 for every class,
        /// so a road shows from the first tile the Protomaps basemap ships it
        /// in (motorways from z4, trunks from z6, primaries from z7,
        /// secondaries from z10, the minor network from z12).
        public var minimumTileZoom: RoadClassValues<Int>

        public init(symbolWidthPoints: RoadClassValues<Float> = RoadMetrics.defaultSymbolWidthPoints,
                    overviewWidthPoints: RoadClassValues<Float> = RoadMetrics.defaultOverviewWidthPoints,
                    overviewZoom: Float = 6,
                    symbolZoom: Float = 14,
                    overviewOpacity: Float = 1,
                    globeOpacity: Float = 0.6,
                    worldLockZoom: Float = 15,
                    drawsCasing: Bool = false,
                    minimumTileZoom: RoadClassValues<Int> = RoadMetrics.defaultMinimumTileZoom) {
            self.symbolWidthPoints = symbolWidthPoints
            self.overviewWidthPoints = overviewWidthPoints
            self.overviewZoom = overviewZoom
            self.symbolZoom = symbolZoom
            self.overviewOpacity = overviewOpacity
            self.globeOpacity = globeOpacity
            self.worldLockZoom = worldLockZoom
            self.drawsCasing = drawsCasing
            self.minimumTileZoom = minimumTileZoom
        }

        /// With every drive tier sharing one asphalt grey, width is the
        /// whole hierarchy, so the ramp is spread wide.
        public static let defaultSymbolWidthPoints = RoadClassValues<Float>(
            motorway: 13.65,
            trunk: 12.7,
            primary: 11.7,
            secondary: 5.0,
            tertiary: 4.5,
            minor: 4.0,
            service: 2.5,
            path: 2.0,
            other: 2.0
        )

        /// The country view's ladder: hairlines whose rank still reads as
        /// width alone.
        public static let defaultOverviewWidthPoints = RoadClassValues<Float>(
            motorway: 1.3,
            trunk: 1.1,
            primary: 0.9,
            secondary: 0.8,
            tertiary: 0.7,
            minor: 0.6,
            service: 0.5,
            path: 0.4,
            other: 0.4
        )

        /// No class is held back: the basemap's own tile levels decide where
        /// each road first appears.
        public static let defaultMinimumTileZoom = RoadClassValues<Int>(
            motorway: 0,
            trunk: 0,
            primary: 0,
            secondary: 0,
            tertiary: 0,
            minor: 0,
            service: 0,
            path: 0,
            other: 0
        )
    }

    /// The biomes of the globe's overview (`OverviewTileSource`): the
    /// colour of each of the fourteen biomes of RESOLVE Ecoregions 2017 the
    /// engine lays into the tiles of the overview zooms, the tones the
    /// tiles' own land cover draws over them in, and the zooms of both. A
    /// biome is a region of one climate and vegetation, so the palette is a
    /// physical atlas's: the forests in the greens, deepest in the tropics
    /// and bluest in the taiga, the grasslands and the savannas in the pale
    /// yellow-greens, the deserts alone in the sand, the tundra in a
    /// grey-green a step off the ice. Everything that grows is a green, so
    /// a cream on the map is dry ground and nothing else. Every value is
    /// baked into the prepared tiles, so a change re-parses them.
    public struct BiomeStyles: Equatable, Sendable {
        /// `tropical_moist_forest`: the Amazon, the Congo, Southeast Asia.
        public var tropicalMoistForest: SIMD4<Float>
        /// `tropical_dry_forest`: the deciduous forests of India, Mexico, the Chaco.
        public var tropicalDryForest: SIMD4<Float>
        /// `tropical_conifer_forest`: the pine forests of Mexico and the Caribbean.
        public var tropicalConiferForest: SIMD4<Float>
        /// `temperate_broadleaf_forest`: Europe, the eastern United States, East Asia.
        public var temperateBroadleafForest: SIMD4<Float>
        /// `temperate_conifer_forest`: the Rockies, the Cascades, the Alps, Siberia's south.
        public var temperateConiferForest: SIMD4<Float>
        /// `boreal_forest`: the taiga of Canada, Scandinavia and Siberia.
        public var borealForest: SIMD4<Float>
        /// `tropical_grassland`: the savannas of Africa, the Cerrado, northern Australia.
        public var tropicalGrassland: SIMD4<Float>
        /// `temperate_grassland`: the prairies, the pampas, the steppes.
        public var temperateGrassland: SIMD4<Float>
        /// `flooded_grassland`: the Pantanal, the Sudd, the Okavango.
        public var floodedGrassland: SIMD4<Float>
        /// `montane_grassland`: the Tibetan plateau, the Andean puna, the Ethiopian highlands.
        public var montaneGrassland: SIMD4<Float>
        /// `tundra`: the Arctic coasts, the Antarctic shore, the high north.
        public var tundra: SIMD4<Float>
        /// `mediterranean_scrub`: the Mediterranean, California, the Cape, southwest Australia.
        public var mediterraneanScrub: SIMD4<Float>
        /// `desert`: the Sahara, Arabia, Central Asia, the Australian outback.
        public var desert: SIMD4<Float>
        /// `mangrove`: the tropical tidal forests.
        public var mangrove: SIMD4<Float>
        /// The forests of the tiles' own land cover and land use drawn over
        /// the biomes, from `coverMinimumTileZoom`: a step darker than the
        /// forest biomes, so a wood reads on them.
        public var forestCover: SIMD4<Float>
        /// The fields drawn over the biomes: the hue of the temperate
        /// forest biomes they mostly lie on, a shade lighter (the same hue
        /// and chroma, the lightness up by a twentieth), so a plain reads
        /// as open land on a wooded biome and the greens layer in one tone,
        /// the biome, the fields on it, the woods on both. Not a
        /// wheat, which stood in one row with the deserts and made France
        /// read as the Sahara, and not a yellower green, which cut the
        /// fields out of the map instead of laying them on it.
        public var farmlandCover: SIMD4<Float>
        /// The bare ground (the basemap's `barren`, the sand and the rock
        /// of the land use) drawn over the biomes: the sand.
        public var barrenCover: SIMD4<Float>
        /// The deepest tile zoom the biomes draw at, 7 by default, the last
        /// zoom the basemap ships its land cover for. Through it the biomes
        /// paint the land in place of the tiles' own land cover and land
        /// use, which draw over them from `coverMinimumTileZoom`, and the
        /// biomes fade out with the land cover over camera zoom 7 to 8,
        /// where the street map's land tone and land use take over. The
        /// overview archive goes to tile zoom 7, so a deeper zoom draws no
        /// biomes. A lower zoom hands the land to the source's land cover
        /// earlier, and a negative zoom never draws the biomes.
        public var maximumTileZoom: Int
        /// The tile zoom from which the tiles' own forests, fields, bare
        /// ground, wetlands and ice draw over the biomes, in the cover tones
        /// above, 2 by default. Under it the globe is the biomes alone, with
        /// the ice and the cities: a region of one climate in one tone. From
        /// it the cover gives the ground its structure, the fields against
        /// the woods, and the holes between the land cover's raster-derived
        /// blobs show the biome instead of bare land.
        public var coverMinimumTileZoom: Int

        public init(tropicalMoistForest: SIMD4<Float> = SIMD4<Float>(0.624, 0.812, 0.541, 1.0),
                    tropicalDryForest: SIMD4<Float> = SIMD4<Float>(0.706, 0.847, 0.580, 1.0),
                    tropicalConiferForest: SIMD4<Float> = SIMD4<Float>(0.651, 0.820, 0.561, 1.0),
                    temperateBroadleafForest: SIMD4<Float> = SIMD4<Float>(0.667, 0.835, 0.576, 1.0),
                    temperateConiferForest: SIMD4<Float> = SIMD4<Float>(0.639, 0.812, 0.576, 1.0),
                    borealForest: SIMD4<Float> = SIMD4<Float>(0.686, 0.827, 0.643, 1.0),
                    tropicalGrassland: SIMD4<Float> = SIMD4<Float>(0.812, 0.886, 0.643, 1.0),
                    temperateGrassland: SIMD4<Float> = SIMD4<Float>(0.788, 0.865, 0.654, 1.0),
                    floodedGrassland: SIMD4<Float> = SIMD4<Float>(0.741, 0.855, 0.698, 1.0),
                    montaneGrassland: SIMD4<Float> = SIMD4<Float>(0.804, 0.863, 0.690, 1.0),
                    tundra: SIMD4<Float> = SIMD4<Float>(0.867, 0.894, 0.839, 1.0),
                    mediterraneanScrub: SIMD4<Float> = SIMD4<Float>(0.788, 0.851, 0.604, 1.0),
                    desert: SIMD4<Float> = SIMD4<Float>(0.949, 0.922, 0.808, 1.0),
                    mangrove: SIMD4<Float> = SIMD4<Float>(0.741, 0.855, 0.698, 1.0),
                    forestCover: SIMD4<Float> = SIMD4<Float>(0.580, 0.770, 0.490, 1.0),
                    farmlandCover: SIMD4<Float> = SIMD4<Float>(0.728, 0.865, 0.654, 1.0),
                    barrenCover: SIMD4<Float> = SIMD4<Float>(0.950, 0.910, 0.780, 1.0),
                    maximumTileZoom: Int = 7,
                    coverMinimumTileZoom: Int = 2) {
            self.tropicalMoistForest = tropicalMoistForest
            self.tropicalDryForest = tropicalDryForest
            self.tropicalConiferForest = tropicalConiferForest
            self.temperateBroadleafForest = temperateBroadleafForest
            self.temperateConiferForest = temperateConiferForest
            self.borealForest = borealForest
            self.tropicalGrassland = tropicalGrassland
            self.temperateGrassland = temperateGrassland
            self.floodedGrassland = floodedGrassland
            self.montaneGrassland = montaneGrassland
            self.tundra = tundra
            self.mediterraneanScrub = mediterraneanScrub
            self.desert = desert
            self.mangrove = mangrove
            self.forestCover = forestCover
            self.farmlandCover = farmlandCover
            self.barrenCover = barrenCover
            self.maximumTileZoom = maximumTileZoom
            self.coverMinimumTileZoom = coverMinimumTileZoom
        }

        /// The atlas palette above.
        public static let `default` = BiomeStyles()

        /// The colours in a fixed order, for the fingerprint.
        var colors: [SIMD4<Float>] {
            [tropicalMoistForest, tropicalDryForest, tropicalConiferForest, temperateBroadleafForest,
             temperateConiferForest, borealForest, tropicalGrassland, temperateGrassland,
             floodedGrassland, montaneGrassland, tundra, mediterraneanScrub, desert, mangrove,
             forestCover, farmlandCover, barrenCover]
        }
    }

    /// The road network of the globe's overview: the Natural Earth 1:10m
    /// roads the engine lays into the tiles of the overview zooms
    /// (`OverviewTileSource`, layer `road`) in place of the basemap's own
    /// roads, which at those zooms are the motorways alone, a few pieces
    /// in most of the world, since the trunks arrive at tile zoom 6. The
    /// network is one continuous line per road, ranked 3 (continental) to
    /// 7 (regional), and draws through `maximumTileZoom`, where the
    /// basemap's trunks take over. The roads of the map's own tiles are
    /// hidden through that zoom. The same tones are what the basemap's own
    /// overview strokes wear on the globe past the network's zoom, through
    /// the unroll into the plane, where the asphalt arrives. Every value is
    /// baked into the prepared tiles, so a change re-parses them.
    public struct OverviewRoadStyles: Equatable, Sendable {
        /// The main roads, rank up to `majorMaximumRank`: the yellow of an
        /// atlas's highways over the painted land.
        public var major: SIMD4<Float>
        /// The rest of the network, thinner and paler.
        public var minor: SIMD4<Float>
        public var majorWidthPoints: Float
        public var minorWidthPoints: Float
        /// The last rank that draws as a main road, 4 by default: the
        /// continental routes and the first regional ones.
        public var majorMaximumRank: Int
        /// The last tile zoom the network draws at, 5 by default, the zoom
        /// before the basemap ships its trunks. The archive carries the
        /// roads through tile zoom 5, so a higher value shows nothing more.
        public var maximumTileZoom: Int

        public init(major: SIMD4<Float> = SIMD4<Float>(0.961, 0.780, 0.302, 1.0),
                    minor: SIMD4<Float> = SIMD4<Float>(0.945, 0.863, 0.600, 1.0),
                    majorWidthPoints: Float = 1.6,
                    minorWidthPoints: Float = 1.0,
                    majorMaximumRank: Int = 4,
                    maximumTileZoom: Int = 5) {
            self.major = major
            self.minor = minor
            self.majorWidthPoints = majorWidthPoints
            self.minorWidthPoints = minorWidthPoints
            self.majorMaximumRank = majorMaximumRank
            self.maximumTileZoom = maximumTileZoom
        }

        public static let `default` = OverviewRoadStyles()
    }

    public struct LayerStyles: Equatable, Sendable {
        public var land: SIMD4<Float>
        public var water: SIMD4<Float>
        public var wood: SIMD4<Float>
        public var grass: SIMD4<Float>
        public var farmland: SIMD4<Float>
        public var ice: SIMD4<Float>
        public var sand: SIMD4<Float>
        public var wetland: SIMD4<Float>
        public var park: SIMD4<Float>
        public var residential: SIMD4<Float>
        public var industrial: SIMD4<Float>
        public var boundary: SIMD4<Float>
        public var aeroway: SIMD4<Float>
        public var roads: RoadLayerStyles
        /// The biomes of the globe's overview, over the land of the
        /// overview zooms in place of the land cover (`BiomeStyles`).
        public var biomes: BiomeStyles
        /// The road network of the globe's overview (`OverviewRoadStyles`).
        public var overviewRoads: OverviewRoadStyles

        public init(land: SIMD4<Float>,
                    water: SIMD4<Float>,
                    wood: SIMD4<Float>,
                    grass: SIMD4<Float>,
                    farmland: SIMD4<Float>,
                    ice: SIMD4<Float>,
                    sand: SIMD4<Float>,
                    wetland: SIMD4<Float>,
                    park: SIMD4<Float>,
                    residential: SIMD4<Float>,
                    industrial: SIMD4<Float>,
                    boundary: SIMD4<Float>,
                    aeroway: SIMD4<Float>,
                    roads: RoadLayerStyles,
                    biomes: BiomeStyles = .default,
                    overviewRoads: OverviewRoadStyles = .default) {
            self.land = land
            self.water = water
            self.wood = wood
            self.grass = grass
            self.farmland = farmland
            self.ice = ice
            self.sand = sand
            self.wetland = wetland
            self.park = park
            self.residential = residential
            self.industrial = industrial
            self.boundary = boundary
            self.aeroway = aeroway
            self.roads = roads
            self.biomes = biomes
            self.overviewRoads = overviewRoads
        }
    }

    public struct FeatureStyles: Equatable, Sendable {
        public var buildingFillColor: SIMD4<Float>
        /// Whether buildings rise out of their footprints on the flat map.
        /// Off, every footprint stays a flat fill in the building colour,
        /// the way buildings draw on the globe. Baked into the prepared
        /// tiles, so a change re-parses them, like any other theme change.
        public var buildingExtrusion: Bool
        /// Whether the POIs and the house numbers inside an extruded
        /// building belong to it: the POI naming the building itself (a
        /// hotel, a mall, the same OSM element as the building) stands on
        /// its roof, the way a skyscraper's name sits on its top, and the
        /// places inside it stay on the ground but are never hidden by the
        /// building they are in, only by the buildings in front of it. Off,
        /// every label stays on the ground and any building can hide it.
        /// Baked into the prepared tiles, so a change re-parses them.
        public var labelsStandOnRoofs: Bool
        /// The radius, in metres, an extruded building's edges are rounded
        /// by (`ExtrusionStyle.edgeRadius`): the corners of its footprint
        /// and the rim of its roof, so the blocks read soft rather than as
        /// sharp boxes. Zero keeps the boxes. Baked into the prepared
        /// tiles, so a change re-parses them.
        public var buildingEdgeRadius: Float

        public init(buildingFillColor: SIMD4<Float>,
                    buildingExtrusion: Bool = true,
                    labelsStandOnRoofs: Bool = true,
                    buildingEdgeRadius: Float = 1.5) {
            self.buildingFillColor = buildingFillColor
            self.buildingExtrusion = buildingExtrusion
            self.labelsStandOnRoofs = labelsStandOnRoofs
            self.buildingEdgeRadius = buildingEdgeRadius
        }
    }

    public var labels: LabelStyles
    /// The labels the globe wears, nil for `labels`: the fill and the halo
    /// of a name on the globe's view, the unroll into the plane included,
    /// come from here and the plane's from `labels`, handed over with the
    /// globe's air at the end of the unroll (`LabelTextStyle.sphereFillColor`,
    /// `sphereStrokeColor`). The size, the weight, the halo's width and
    /// the opacity are always those of `labels`. The night palette sets
    /// the day's here, with `globeLayers`. Baked into the prepared tiles,
    /// so a change re-parses them.
    public var globeLabels: LabelStyles?
    public var labelVisibility: LabelVisibility
    public var layers: LayerStyles
    /// The palette the globe wears, nil for `layers`: the ground of the
    /// globe's view, the unroll into the plane included, takes its colours
    /// from here and the plane from `layers`, handed over with the globe's
    /// air at the end of the unroll (`FillStyle.sphereColor`,
    /// `LinePass.sphereColor`). The night palette sets the day's here, so
    /// the planet keeps its daylight and its sun while the map in it is
    /// dark. The caps past the poles follow it. Baked into the prepared
    /// tiles, so a change re-parses them.
    public var globeLayers: LayerStyles?
    public var features: FeatureStyles
    public var roadMetrics: RoadMetrics
    public var routeShields: RouteShields
    /// How the slopes are shaded where the ground relief stands
    /// (`ImmersiveMapHillshade`).
    public var hillshade: ImmersiveMapHillshade
    /// How the ground is darkened where the terrain hides the sky, where
    /// the ground relief stands (`ImmersiveMapTerrainOcclusion`).
    public var terrainOcclusion: ImmersiveMapTerrainOcclusion

    public init(labels: LabelStyles = .default,
                globeLabels: LabelStyles? = nil,
                labelVisibility: LabelVisibility = LabelVisibility(),
                layers: LayerStyles = .default,
                globeLayers: LayerStyles? = nil,
                features: FeatureStyles = .default,
                roadMetrics: RoadMetrics = RoadMetrics(),
                routeShields: RouteShields = RouteShields(),
                hillshade: ImmersiveMapHillshade = ImmersiveMapHillshade(),
                terrainOcclusion: ImmersiveMapTerrainOcclusion = ImmersiveMapTerrainOcclusion()) {
        self.labels = labels
        self.globeLabels = globeLabels
        self.labelVisibility = labelVisibility
        self.layers = layers
        self.globeLayers = globeLayers
        self.features = features
        self.roadMetrics = roadMetrics
        self.routeShields = routeShields
        self.hillshade = hillshade
        self.terrainOcclusion = terrainOcclusion
    }

    public static let `default` = ProtomapsBasemapTheme()

    /// What no tile paints, from the same palette: the land where no tile
    /// has arrived, the water past the northern rim, the ice past the
    /// southern one. The caps are the globe's, so they wear the globe's
    /// palette where the theme has one.
    public var baseColors: ImmersiveMapBaseColors {
        let globe = globeLayers ?? layers
        return ImmersiveMapBaseColors(map: layers.land, northCap: globe.water, southCap: globe.ice)
    }

    /// A copy with the changes the closure makes: the way to state a theme
    /// as the default plus a few differences.
    public func apply(_ change: (inout ProtomapsBasemapTheme) -> Void) -> ProtomapsBasemapTheme {
        var copy = self
        change(&copy)
        return copy
    }

    public func labels(_ update: (inout LabelStyles) -> Void) -> ProtomapsBasemapTheme {
        var copy = self
        update(&copy.labels)
        return copy
    }

    public func labelVisibility(_ update: (inout LabelVisibility) -> Void)
        -> ProtomapsBasemapTheme {
        var copy = self
        update(&copy.labelVisibility)
        return copy
    }

    public func layers(_ update: (inout LayerStyles) -> Void) -> ProtomapsBasemapTheme {
        var copy = self
        update(&copy.layers)
        return copy
    }

    /// A copy whose globe wears its own palette, the changes made to the
    /// globe's palette so far or, where the theme has none, to `layers`.
    public func globeLayers(_ update: (inout LayerStyles) -> Void) -> ProtomapsBasemapTheme {
        var copy = self
        var globe = globeLayers ?? layers
        update(&globe)
        copy.globeLayers = globe
        return copy
    }

    /// A copy whose globe wears its own labels, the changes made to the
    /// globe's labels so far or, where the theme has none, to `labels`.
    public func globeLabels(_ update: (inout LabelStyles) -> Void) -> ProtomapsBasemapTheme {
        var copy = self
        var globe = globeLabels ?? labels
        update(&globe)
        copy.globeLabels = globe
        return copy
    }

    public func features(_ update: (inout FeatureStyles) -> Void) -> ProtomapsBasemapTheme {
        var copy = self
        update(&copy.features)
        return copy
    }

    public func roadMetrics(_ update: (inout RoadMetrics) -> Void) -> ProtomapsBasemapTheme {
        var copy = self
        update(&copy.roadMetrics)
        return copy
    }

    public func routeShields(_ update: (inout RouteShields) -> Void) -> ProtomapsBasemapTheme {
        var copy = self
        update(&copy.routeShields)
        return copy
    }

    /// FNV-1a over every palette component so a recolor changes disk-cache identity.
    var cacheFingerprint: UInt32 {
        var hash: UInt64 = 1469598103934665603
        for value in paletteComponents {
            var bits = value == 0 ? Float(0).bitPattern : value.bitPattern
            withUnsafeBytes(of: &bits) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 1099511628211
                }
            }
        }
        let folded = UInt32(truncatingIfNeeded: hash) ^ UInt32(truncatingIfNeeded: hash >> 32)
        return folded == 0 ? 1 : folded
    }

    private var paletteComponents: [Float] {
        var out: [Float] = []
        func add(_ v: SIMD4<Float>) { out.append(contentsOf: [v.x, v.y, v.z, v.w]) }
        func add(_ v: SIMD3<Float>) { out.append(contentsOf: [v.x, v.y, v.z]) }
        func add(_ a: LabelAppearance) {
            add(a.fillColor); add(a.strokeColor)
            out.append(contentsOf: [a.haloEm, a.sizePoints, Float(a.weight.rawValue), a.uppercased ? 1 : 0,
                                    a.emboldenPoints, a.letterSpacingEm, a.opacity])
        }
        func add(_ layers: LayerStyles) {
            add(layers.land); add(layers.water); add(layers.wood); add(layers.grass)
            add(layers.farmland); add(layers.ice); add(layers.sand); add(layers.wetland)
            add(layers.park); add(layers.residential); add(layers.industrial)
            add(layers.boundary); add(layers.aeroway)
            add(layers.roads.motorway); add(layers.roads.trunk); add(layers.roads.primary)
            add(layers.roads.secondary); add(layers.roads.tertiary); add(layers.roads.minor)
            add(layers.roads.service); add(layers.roads.path); add(layers.roads.rail)
            add(layers.roads.casing); add(layers.roads.marking)
            // The biomes are baked into the overview zooms' tiles, and the
            // zoom they stop at decides which tiles carry them at all.
            for color in layers.biomes.colors { add(color) }
            out.append(Float(layers.biomes.maximumTileZoom))
            out.append(Float(layers.biomes.coverMinimumTileZoom))
            // The overview's road network, baked into the same tiles.
            add(layers.overviewRoads.major); add(layers.overviewRoads.minor)
            out.append(contentsOf: [layers.overviewRoads.majorWidthPoints, layers.overviewRoads.minorWidthPoints,
                                    Float(layers.overviewRoads.majorMaximumRank), Float(layers.overviewRoads.maximumTileZoom)])
        }
        add(layers)
        // The globe's palette is baked into the same tiles as the colours
        // the ground wears on the sphere, none where the theme has none.
        if let globeLayers {
            out.append(1)
            add(globeLayers)
        } else {
            out.append(0)
        }
        add(features.buildingFillColor)
        out.append(features.buildingExtrusion ? 1 : 0)
        out.append(features.labelsStandOnRoofs ? 1 : 0)
        out.append(features.buildingEdgeRadius)
        add(labels.city); add(labels.town); add(labels.district); add(labels.country); add(labels.region)
        add(labels.poi); add(labels.water); add(labels.road)
        // The globe's labels are baked into the tiles as the colours a name
        // wears on the sphere, none where the theme has none.
        if let globeLabels {
            out.append(1)
            add(globeLabels.city); add(globeLabels.town); add(globeLabels.district)
            add(globeLabels.country); add(globeLabels.region)
            add(globeLabels.poi); add(globeLabels.water); add(globeLabels.road)
        } else {
            out.append(0)
        }
        // Not palette values, but they change which labels are drawn, so they
        // must participate in the disk-cache identity.
        out.append(Float(labelVisibility.poiIconlessMinimumZoom))
        out.append(Float(labelVisibility.poiMinimumZoom))
        out.append(labelVisibility.poiRequiresIcon ? 1 : 0)
        out.append(labelVisibility.poiFollowsSourceMinimumZoom ? 1 : 0)
        out.append(contentsOf: [labelVisibility.poiCategoryMinimumZoom.campus,
                                labelVisibility.poiCategoryMinimumZoom.shop,
                                labelVisibility.poiCategoryMinimumZoom.service,
                                labelVisibility.poiCategoryMinimumZoom.transitDetail,
                                labelVisibility.poiLongNameMinimumZoom,
                                labelVisibility.poiLongNameCharacterCount,
                                labelVisibility.addressMinimumZoom,
                                labelVisibility.countryMaximumZoom,
                                labelVisibility.regionMaximumZoom].map(Float.init))
        out.append(labelVisibility.localDetailInLookAtTileOnly ? 1 : 0)
        // The road metrics are baked into the tiles' line styles and decide
        // which classes a tile carries at all.
        out.append(contentsOf: roadMetrics.symbolWidthPoints.all)
        out.append(contentsOf: roadMetrics.overviewWidthPoints.all)
        out.append(contentsOf: [roadMetrics.overviewZoom, roadMetrics.symbolZoom, roadMetrics.overviewOpacity])
        out.append(roadMetrics.globeOpacity)
        out.append(roadMetrics.worldLockZoom)
        out.append(roadMetrics.drawsCasing ? 1 : 0)
        out.append(contentsOf: roadMetrics.minimumTileZoom.all.map(Float.init))
        // The route signs are baked into the tiles as labels.
        out.append(contentsOf: routeShields.fingerprintComponents)
        return out
    }
}

public extension ProtomapsBasemapTheme.LayerStyles {
    /// A light, warm, low-contrast palette in the manner of the system maps
    /// people already know: a warm off-white ground, soft pastel greens, a
    /// clear light blue for water, and asphalt-grey streets whose majors run
    /// wider, not darker. Contrast is spent on what carries meaning
    /// (water, parks, the road hierarchy) and taken out of everything that
    /// used to compete with the labels and the buildings for attention.
    static let `default` = ProtomapsBasemapTheme.LayerStyles(
        land: SIMD4<Float>(0.973, 0.965, 0.941, 1.0),
        water: SIMD4<Float>(0.647, 0.812, 0.945, 1.0),
        // Landcover greens are opaque: they cover whole tiles (a tile can be entirely
        // forest/grass), and a translucent green over the near-white `land` base reads
        // as a washed, pale fill - and does so per-whole-tile, so adjacent tiles jump
        // in tone. Opaque keeps the green saturated and consistent.
        wood: SIMD4<Float>(0.667, 0.835, 0.576, 1.0),
        grass: SIMD4<Float>(0.757, 0.886, 0.643, 1.0),
        // Farmland is a pale wheat, not a green: cultivated land covers most of
        // a continental plain (65% of a Central-Russia overview tile), and as a
        // green it merged with woods and grass into one camouflage field. As a
        // near-ground cream it recedes, and forests read as green shapes on a
        // light land the way region maps draw them.
        farmland: SIMD4<Float>(0.914, 0.922, 0.792, 1.0),
        ice: SIMD4<Float>(0.937, 0.957, 0.973, 1.0),
        sand: SIMD4<Float>(0.949, 0.922, 0.808, 1.0),
        // Wetland/bog covers huge areas in Russia's lowlands; a near-grey tint made
        // whole regions read as desaturated. A muted green reads as the vegetation it is.
        wetland: SIMD4<Float>(0.741, 0.855, 0.698, 1.0),
        park: SIMD4<Float>(0.757, 0.886, 0.643, 1.0),
        // The built-up tints sit a hair under the ground: enough that a city
        // reads as a city over a region view, not enough to grey the streets.
        residential: SIMD4<Float>(0.961, 0.945, 0.914, 1.0),
        industrial: SIMD4<Float>(0.949, 0.941, 0.925, 1.0),
        boundary: SIMD4<Float>(0.52, 0.15, 0.72, 0.9),
        aeroway: SIMD4<Float>(0.886, 0.882, 0.902, 1.0),
        roads: .default
    )
}

public extension ProtomapsBasemapTheme.RoadLayerStyles {
    /// Asphalt streets in the driving-map manner: every drive tier is the
    /// same cool neutral grey, one road surface across the network, and
    /// importance reads as width alone, motorways widest down to narrow
    /// service alleys. Paths keep their warm gravel tone (they are not
    /// asphalt) and the casing the style derives from these fills is a
    /// uniformly darker grey, so every road sits in a slightly deeper edge.
    static let `default` = ProtomapsBasemapTheme.RoadLayerStyles(
        motorway: SIMD4<Float>(0.757, 0.769, 0.784, 1.0),
        trunk: SIMD4<Float>(0.757, 0.769, 0.784, 1.0),
        primary: SIMD4<Float>(0.757, 0.769, 0.784, 1.0),
        secondary: SIMD4<Float>(0.757, 0.769, 0.784, 1.0),
        tertiary: SIMD4<Float>(0.757, 0.769, 0.784, 1.0),
        minor: SIMD4<Float>(0.757, 0.769, 0.784, 1.0),
        service: SIMD4<Float>(0.757, 0.769, 0.784, 1.0),
        // A pedestrian path is a warm sand tone a clear step under the
        // ground, the way Apple draws park walks: visible against the beige
        // land AND against park green, yet quiet enough that the footway
        // network stays a texture rather than a second road system. It used
        // to be the exact ground off-white, which made every path invisible
        // until it crossed a park.
        path: SIMD4<Float>(0.898, 0.871, 0.812, 1.0),
        rail: SIMD4<Float>(0.741, 0.741, 0.765, 1.0),
        casing: SIMD4<Float>(0.718, 0.725, 0.735, 1.0)
    )
}

public extension ProtomapsBasemapTheme.FeatureStyles {
    /// A warm light grey a step under the ground: the roof of a building
    /// separates from the street around it, and its walls, which the renderer
    /// shades down from this, separate from the roof.
    static let `default` = ProtomapsBasemapTheme.FeatureStyles(
        buildingFillColor: SIMD4<Float>(0.906, 0.890, 0.863, 1.0)
    )
}

public extension ProtomapsBasemapTheme.LabelStyles {
    /// Sizes are layout points: the pixel size this style used before labels
    /// carried a unit, divided by the 2x reference scale the palette was
    /// authored against.
    ///
    /// The curve below is the design, not the final size. Sizes are raised to
    /// `LabelTypeScale.minimumSizePoints` where they fall under the floor for
    /// readable type, and that happens once, where a style is resolved, so that
    /// a class derived from another (an ocean label is the water appearance a
    /// few points larger) is measured against the floor after its own
    /// adjustment rather than on top of a base that was already lifted.
    static let `default` = ProtomapsBasemapTheme.LabelStyles(
        city: ProtomapsBasemapTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.20, 0.20, 0.22), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.153, sizePoints: 15, weight: .bold),
        town: ProtomapsBasemapTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.30, 0.30, 0.32), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.173, sizePoints: 11, weight: .thin),
        // The districts are lettered like the streets, the deep black
        // being the cities' alone: light grey capitals in the thin face
        // with a little added weight and a narrow halo, so a district
        // names the stretch of the city it lies over without standing out
        // of it.
        district: ProtomapsBasemapTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.45, 0.45, 0.46), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.1, sizePoints: 10, weight: .thin, uppercased: true, emboldenPoints: 0.2),
        // A country's name is the name of a land: spaced capitals in the
        // thin face with a little added weight, a shade above a capital's
        // size (16.5), in a lighter grey of its own with a narrow halo, so
        // it reads as lettering over the country and not as one more
        // town, and a globe full of them stays quiet. Both are lettering
        // laid over the land, so they let the map show through them. A
        // region's name is the same manner, a city's size and lighter
        // still.
        country: ProtomapsBasemapTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.38, 0.37, 0.44), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.1, sizePoints: 17, weight: .thin, uppercased: true, emboldenPoints: 0.3,
            letterSpacingEm: 0.12, opacity: 0.65),
        region: ProtomapsBasemapTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.46, 0.45, 0.51), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.1, sizePoints: 15, weight: .thin, uppercased: true, emboldenPoints: 0.3,
            letterSpacingEm: 0.1, opacity: 0.7),
        poi: ProtomapsBasemapTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.40, 0.42, 0.40), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.225, sizePoints: 8, weight: .thin),
        // The water names lie on the water: a deeper blue of its own hue
        // and no halo, so they read as part of the surface.
        water: ProtomapsBasemapTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.29, 0.49, 0.71), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0, sizePoints: 9.5, weight: .thin),
        // The street names stay under the places and the landmarks: small
        // light grey capitals in the thin face with a little added weight
        // and a narrow halo, the way a commercial map letters its streets,
        // so a street reads as a street and never outweighs the city it
        // runs through.
        road: ProtomapsBasemapTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.45, 0.45, 0.46), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.1, sizePoints: 11, weight: .thin, uppercased: true, emboldenPoints: 0.2)
    )
}
