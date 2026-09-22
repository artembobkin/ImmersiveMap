// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The look of the built-in style as plain values: the colour of every
/// layer and road class, the building fill, the label appearances and which
/// labels show. An app recolours the map by changing a field of the default
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
/// change rebakes the prepared tiles by itself.
public struct ImmersiveMapTilesTheme: Equatable, Sendable {
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

        public init(fillColor: SIMD3<Float>,
                    strokeColor: SIMD3<Float>,
                    haloEm: Float,
                    sizePoints: Float,
                    weight: LabelFontWeight) {
            self.fillColor = fillColor
            self.strokeColor = strokeColor
            self.haloEm = haloEm
            self.sizePoints = sizePoints
            self.weight = weight
        }
    }

    public struct LabelStyles: Equatable, Sendable {
        public var city: LabelAppearance
        public var town: LabelAppearance
        public var country: LabelAppearance
        public var poi: LabelAppearance
        public var water: LabelAppearance
        public var road: LabelAppearance

        public init(city: LabelAppearance,
                    town: LabelAppearance,
                    country: LabelAppearance,
                    poi: LabelAppearance,
                    water: LabelAppearance,
                    road: LabelAppearance) {
            self.city = city
            self.town = town
            self.country = country
            self.poi = poi
            self.water = water
            self.road = road
        }
    }

    /// Zoom thresholds that decide whether a label class is drawn at all (as
    /// opposed to `LabelStyles`, which only decides how a drawn label looks).
    public struct LabelVisibility: Equatable, Sendable {
        /// Whether a POI needs an icon to be labelled at all.
        ///
        /// A category the icon set does not recognize (an office, a company, a
        /// monument, a named building) has nothing to draw but its name, and
        /// those names are the bulk of a city centre's POIs: bare text over the
        /// buildings, in the type size of a landmark, saying nothing about what
        /// the place is. The default is to leave them out, so the map carries
        /// the categories it can actually depict. Set to `false` to draw them
        /// as text, from `poiIconlessMinimumZoom`.
        public var poiRequiresIcon: Bool

        /// Minimum tile zoom from which icon-less POIs (offices, companies, and
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

        public init(poiIconlessMinimumZoom: Int = 16,
                    poiMinimumZoom: Int = 0,
                    poiRequiresIcon: Bool = true) {
            self.poiIconlessMinimumZoom = poiIconlessMinimumZoom
            self.poiMinimumZoom = poiMinimumZoom
            self.poiRequiresIcon = poiRequiresIcon
        }
    }

    /// One entry per OpenMapTiles `transportation.class` tier used by the style.
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

        public init(motorway: SIMD4<Float>,
                    trunk: SIMD4<Float>,
                    primary: SIMD4<Float>,
                    secondary: SIMD4<Float>,
                    tertiary: SIMD4<Float>,
                    minor: SIMD4<Float>,
                    service: SIMD4<Float>,
                    path: SIMD4<Float>,
                    rail: SIMD4<Float>,
                    casing: SIMD4<Float>) {
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
        }
    }

    /// One value per road class of the hosted tiles' `transportation`
    /// layer, `other` standing for every class the style does not name.
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

        /// The value of a `class` as the tiles spell it (`track` reads as
        /// `path`).
        public func value(forClass cls: String?) -> Value {
            switch cls {
            case "motorway": return motorway
            case "trunk": return trunk
            case "primary": return primary
            case "secondary": return secondary
            case "tertiary": return tertiary
            case "minor": return minor
            case "service": return service
            case "path", "track": return path
            default: return other
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

        /// The opacity of the overview stroke, a veil that lets the ground
        /// colours stay the picture over a country view. It grows to one
        /// along with the width, by `symbolZoom`.
        public var overviewOpacity: Float

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

        /// The tile zoom a class first draws at. The street era draws what
        /// the tiles carry from this zoom on. A value under the zoom the
        /// source first ships the class at changes nothing.
        public var minimumTileZoom: RoadClassValues<Int>

        public init(symbolWidthPoints: RoadClassValues<Float> = RoadMetrics.defaultSymbolWidthPoints,
                    overviewWidthPoints: RoadClassValues<Float> = RoadMetrics.defaultOverviewWidthPoints,
                    overviewZoom: Float = 6,
                    symbolZoom: Float = 14,
                    overviewOpacity: Float = 0.6,
                    worldLockZoom: Float = 15,
                    drawsCasing: Bool = false,
                    minimumTileZoom: RoadClassValues<Int> = RoadMetrics.defaultMinimumTileZoom) {
            self.symbolWidthPoints = symbolWidthPoints
            self.overviewWidthPoints = overviewWidthPoints
            self.overviewZoom = overviewZoom
            self.symbolZoom = symbolZoom
            self.overviewOpacity = overviewOpacity
            self.worldLockZoom = worldLockZoom
            self.drawsCasing = drawsCasing
            self.minimumTileZoom = minimumTileZoom
        }

        /// With every drive tier sharing one asphalt grey, width is the
        /// whole hierarchy, so the ramp is spread wide.
        public static let defaultSymbolWidthPoints = RoadClassValues<Float>(
            motorway: 10.5,
            trunk: 9.75,
            primary: 9.0,
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

        /// Majors carry a country view. The small automobile network, the
        /// service roads and the paths join together at street zoom: over a
        /// city view they only grey the map.
        public static let defaultMinimumTileZoom = RoadClassValues<Int>(
            motorway: 5,
            trunk: 5,
            primary: 7,
            secondary: 9,
            tertiary: 10,
            minor: 14,
            service: 14,
            path: 14,
            other: 14
        )
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
                    roads: RoadLayerStyles) {
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
        }
    }

    public struct FeatureStyles: Equatable, Sendable {
        public var buildingFillColor: SIMD4<Float>
        /// Whether buildings rise out of their footprints on the flat map.
        /// Off, every footprint stays a flat fill in the building colour,
        /// the way buildings draw on the globe. Baked into the prepared
        /// tiles, so a change re-parses them, like any other theme change.
        public var buildingExtrusion: Bool
        /// Whether buildings raise the shaped roofs (gabled, hipped,
        /// skillion, domes and the rest) the schema reading found on them.
        /// Off, every building gets a flat lid at its full height.
        public var buildingRoofShapes: Bool

        public init(buildingFillColor: SIMD4<Float>,
                    buildingExtrusion: Bool = true,
                    buildingRoofShapes: Bool = false) {
            self.buildingFillColor = buildingFillColor
            self.buildingExtrusion = buildingExtrusion
            self.buildingRoofShapes = buildingRoofShapes
        }
    }

    public var labels: LabelStyles
    public var labelVisibility: LabelVisibility
    public var layers: LayerStyles
    public var features: FeatureStyles
    public var roadMetrics: RoadMetrics

    public init(labels: LabelStyles = .default,
                labelVisibility: LabelVisibility = LabelVisibility(),
                layers: LayerStyles = .default,
                features: FeatureStyles = .default,
                roadMetrics: RoadMetrics = RoadMetrics()) {
        self.labels = labels
        self.labelVisibility = labelVisibility
        self.layers = layers
        self.features = features
        self.roadMetrics = roadMetrics
    }

    public static let `default` = ImmersiveMapTilesTheme()

    /// What no tile paints, from the same palette: the land where no tile
    /// has arrived, the water past the northern rim, the ice past the
    /// southern one.
    public var baseColors: ImmersiveMapBaseColors {
        ImmersiveMapBaseColors(map: layers.land, northCap: layers.water, southCap: layers.ice)
    }

    /// A copy with the changes the closure makes: the way to state a theme
    /// as the default plus a few differences.
    public func apply(_ change: (inout ImmersiveMapTilesTheme) -> Void) -> ImmersiveMapTilesTheme {
        var copy = self
        change(&copy)
        return copy
    }

    public func labels(_ update: (inout LabelStyles) -> Void) -> ImmersiveMapTilesTheme {
        var copy = self
        update(&copy.labels)
        return copy
    }

    public func labelVisibility(_ update: (inout LabelVisibility) -> Void)
        -> ImmersiveMapTilesTheme {
        var copy = self
        update(&copy.labelVisibility)
        return copy
    }

    public func layers(_ update: (inout LayerStyles) -> Void) -> ImmersiveMapTilesTheme {
        var copy = self
        update(&copy.layers)
        return copy
    }

    public func features(_ update: (inout FeatureStyles) -> Void) -> ImmersiveMapTilesTheme {
        var copy = self
        update(&copy.features)
        return copy
    }

    public func roadMetrics(_ update: (inout RoadMetrics) -> Void) -> ImmersiveMapTilesTheme {
        var copy = self
        update(&copy.roadMetrics)
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
            out.append(contentsOf: [a.haloEm, a.sizePoints, Float(a.weight.rawValue)])
        }
        add(layers.land); add(layers.water); add(layers.wood); add(layers.grass)
        add(layers.farmland); add(layers.ice); add(layers.sand); add(layers.wetland)
        add(layers.park); add(layers.residential); add(layers.industrial)
        add(layers.boundary); add(layers.aeroway)
        add(layers.roads.motorway); add(layers.roads.trunk); add(layers.roads.primary)
        add(layers.roads.secondary); add(layers.roads.tertiary); add(layers.roads.minor)
        add(layers.roads.service); add(layers.roads.path); add(layers.roads.rail)
        add(layers.roads.casing)
        add(features.buildingFillColor)
        out.append(contentsOf: [features.buildingExtrusion ? 1 : 0, features.buildingRoofShapes ? 1 : 0])
        add(labels.city); add(labels.town); add(labels.country)
        add(labels.poi); add(labels.water); add(labels.road)
        // Not palette values, but they change which labels are drawn, so they
        // must participate in the disk-cache identity.
        out.append(Float(labelVisibility.poiIconlessMinimumZoom))
        out.append(Float(labelVisibility.poiMinimumZoom))
        out.append(labelVisibility.poiRequiresIcon ? 1 : 0)
        // The road metrics are baked into the tiles' line styles and decide
        // which classes a tile carries at all.
        out.append(contentsOf: roadMetrics.symbolWidthPoints.all)
        out.append(contentsOf: roadMetrics.overviewWidthPoints.all)
        out.append(contentsOf: [roadMetrics.overviewZoom, roadMetrics.symbolZoom, roadMetrics.overviewOpacity])
        out.append(roadMetrics.worldLockZoom)
        out.append(roadMetrics.drawsCasing ? 1 : 0)
        out.append(contentsOf: roadMetrics.minimumTileZoom.all.map(Float.init))
        return out
    }
}

public extension ImmersiveMapTilesTheme.LayerStyles {
    /// A light, warm, low-contrast palette in the manner of the system maps
    /// people already know: a warm off-white ground, soft pastel greens, a
    /// clear light blue for water, and asphalt-grey streets whose majors run
    /// wider, not darker. Contrast is spent on what carries meaning
    /// (water, parks, the road hierarchy) and taken out of everything that
    /// used to compete with the labels and the buildings for attention.
    static let `default` = ImmersiveMapTilesTheme.LayerStyles(
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

public extension ImmersiveMapTilesTheme.RoadLayerStyles {
    /// Asphalt streets in the driving-map manner: every drive tier is the
    /// same cool neutral grey, one road surface across the network, and
    /// importance reads as width alone, motorways widest down to narrow
    /// service alleys. Paths keep their warm gravel tone (they are not
    /// asphalt) and the casing the style derives from these fills is a
    /// uniformly darker grey, so every road sits in a slightly deeper edge.
    static let `default` = ImmersiveMapTilesTheme.RoadLayerStyles(
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

public extension ImmersiveMapTilesTheme.FeatureStyles {
    /// A warm light grey a step under the ground: the roof of a building
    /// separates from the street around it, and its walls, which the renderer
    /// shades down from this, separate from the roof.
    static let `default` = ImmersiveMapTilesTheme.FeatureStyles(
        buildingFillColor: SIMD4<Float>(0.906, 0.890, 0.863, 1.0)
    )
}

public extension ImmersiveMapTilesTheme.LabelStyles {
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
    static let `default` = ImmersiveMapTilesTheme.LabelStyles(
        city: ImmersiveMapTilesTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.20, 0.20, 0.22), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.153, sizePoints: 15, weight: .bold),
        town: ImmersiveMapTilesTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.30, 0.30, 0.32), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.173, sizePoints: 11, weight: .thin),
        country: ImmersiveMapTilesTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.28, 0.27, 0.33), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.162, sizePoints: 13, weight: .bold),
        poi: ImmersiveMapTilesTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.40, 0.42, 0.40), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.225, sizePoints: 8, weight: .thin),
        water: ImmersiveMapTilesTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.24, 0.44, 0.68), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.168, sizePoints: 9.5, weight: .thin),
        road: ImmersiveMapTilesTheme.LabelAppearance(
            fillColor: SIMD3<Float>(0.30, 0.30, 0.30), strokeColor: SIMD3<Float>(1, 1, 1),
            haloEm: 0.106, sizePoints: 17, weight: .bold)
    )
}
