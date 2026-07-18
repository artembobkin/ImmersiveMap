// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Tunable palette for `ImmersiveMapTilesDefaultMapStyle`. Mirrors the shape of the
/// Mapbox configuration so hosts can recolor the first-party
/// OpenMapTiles basemap without touching the layer logic.
public struct ImmersiveMapTilesDefaultMapStyleConfiguration: Equatable, Sendable {
    public struct LabelAppearance: Equatable, Sendable {
        public var fillColor: SIMD3<Float>
        public var strokeColor: SIMD3<Float>
        public var strokeWidthPx: Float
        public var sizePx: Float
        public var weight: LabelFontWeight

        public init(fillColor: SIMD3<Float>,
                    strokeColor: SIMD3<Float>,
                    strokeWidthPx: Float,
                    sizePx: Float,
                    weight: LabelFontWeight) {
            self.fillColor = fillColor
            self.strokeColor = strokeColor
            self.strokeWidthPx = strokeWidthPx
            self.sizePx = sizePx
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
        /// Минимальный tile-zoom, с которого рисуются POI без иконки (офисы,
        /// компании и прочие категории вне набора распознаваемых иконок). POI с
        /// иконкой рисуются с обычного порога, поэтому на обзорных зумах остаются
        /// только иконочные POI, а плотная россыпь текстовых подписей включается
        /// глубже.
        public var poiIconlessMinimumZoom: Int

        public init(poiIconlessMinimumZoom: Int = 16) {
            self.poiIconlessMinimumZoom = poiIconlessMinimumZoom
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

    /// Palette used only by the continuous ESA WorldCover overlay at overview
    /// zooms. Keeping it separate prevents globe-scale color choices from tinting
    /// the detailed OSM street map that takes over above z9.
    public struct GlobalLandcoverStyles: Equatable, Sendable {
        public var land: SIMD4<Float>
        public var water: SIMD4<Float>
        public var forest: SIMD4<Float>
        public var grass: SIMD4<Float>
        public var crop: SIMD4<Float>
        public var barren: SIMD4<Float>
        public var wetland: SIMD4<Float>
        public var snow: SIMD4<Float>

        public init(land: SIMD4<Float>,
                    water: SIMD4<Float>,
                    forest: SIMD4<Float>,
                    grass: SIMD4<Float>,
                    crop: SIMD4<Float>,
                    barren: SIMD4<Float>,
                    wetland: SIMD4<Float>,
                    snow: SIMD4<Float>) {
            self.land = land
            self.water = water
            self.forest = forest
            self.grass = grass
            self.crop = crop
            self.barren = barren
            self.wetland = wetland
            self.snow = snow
        }
    }

    public struct FeatureStyles: Equatable, Sendable {
        public var buildingFillColor: SIMD4<Float>

        public init(buildingFillColor: SIMD4<Float>) {
            self.buildingFillColor = buildingFillColor
        }
    }

    public var labels: LabelStyles
    public var labelVisibility: LabelVisibility
    public var layers: LayerStyles
    public var features: FeatureStyles
    public var globalLandcover: GlobalLandcoverStyles

    public init(labels: LabelStyles = .immersiveMapTilesDefault,
                labelVisibility: LabelVisibility = LabelVisibility(),
                layers: LayerStyles = .immersiveMapTilesDefault,
                features: FeatureStyles = .immersiveMapTilesDefault,
                globalLandcover: GlobalLandcoverStyles = .softBiomes) {
        self.labels = labels
        self.labelVisibility = labelVisibility
        self.layers = layers
        self.features = features
        self.globalLandcover = globalLandcover
    }

    public static let immersiveMapTilesDefault = ImmersiveMapTilesDefaultMapStyleConfiguration()

    public func labels(_ update: (inout LabelStyles) -> Void) -> ImmersiveMapTilesDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.labels)
        return copy
    }

    public func labelVisibility(_ update: (inout LabelVisibility) -> Void)
        -> ImmersiveMapTilesDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.labelVisibility)
        return copy
    }

    public func layers(_ update: (inout LayerStyles) -> Void) -> ImmersiveMapTilesDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.layers)
        return copy
    }

    public func features(_ update: (inout FeatureStyles) -> Void) -> ImmersiveMapTilesDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.features)
        return copy
    }

    public func globalLandcover(_ update: (inout GlobalLandcoverStyles) -> Void)
        -> ImmersiveMapTilesDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.globalLandcover)
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
            out.append(contentsOf: [a.strokeWidthPx, a.sizePx, Float(a.weight.rawValue)])
        }
        add(layers.land); add(layers.water); add(layers.wood); add(layers.grass)
        add(layers.farmland); add(layers.ice); add(layers.sand); add(layers.wetland)
        add(layers.park); add(layers.residential); add(layers.industrial)
        add(layers.boundary); add(layers.aeroway)
        add(layers.roads.motorway); add(layers.roads.trunk); add(layers.roads.primary)
        add(layers.roads.secondary); add(layers.roads.tertiary); add(layers.roads.minor)
        add(layers.roads.service); add(layers.roads.path); add(layers.roads.rail)
        add(layers.roads.casing)
        add(globalLandcover.land); add(globalLandcover.water); add(globalLandcover.forest)
        add(globalLandcover.grass); add(globalLandcover.crop); add(globalLandcover.barren)
        add(globalLandcover.wetland); add(globalLandcover.snow)
        add(features.buildingFillColor)
        add(labels.city); add(labels.town); add(labels.country)
        add(labels.poi); add(labels.water); add(labels.road)
        // Not a palette value, but it changes which labels are drawn, so it must
        // participate in the disk-cache identity.
        out.append(Float(labelVisibility.poiIconlessMinimumZoom))
        return out
    }
}

public extension ImmersiveMapTilesDefaultMapStyleConfiguration.GlobalLandcoverStyles {
    /// Low-contrast overview palette: a continuous sage land base hides sparse
    /// source-data gaps, while broad biome classes remain distinguishable without
    /// turning the globe into a high-contrast categorical mosaic.
    static let softBiomes = ImmersiveMapTilesDefaultMapStyleConfiguration.GlobalLandcoverStyles(
        land: SIMD4<Float>(0.722, 0.784, 0.596, 1.0),
        water: SIMD4<Float>(0.302, 0.600, 0.902, 1.0),
        forest: SIMD4<Float>(0.502, 0.627, 0.408, 1.0),
        grass: SIMD4<Float>(0.627, 0.722, 0.502, 1.0),
        crop: SIMD4<Float>(0.722, 0.753, 0.565, 1.0),
        barren: SIMD4<Float>(0.941, 0.878, 0.753, 1.0),
        wetland: SIMD4<Float>(0.533, 0.659, 0.439, 1.0),
        snow: SIMD4<Float>(0.949, 0.953, 0.937, 1.0)
    )
}

public extension ImmersiveMapTilesDefaultMapStyleConfiguration.LayerStyles {
    static let immersiveMapTilesDefault = ImmersiveMapTilesDefaultMapStyleConfiguration.LayerStyles(
        land: SIMD4<Float>(0.941, 0.937, 0.910, 1.0),
        water: SIMD4<Float>(0.667, 0.808, 0.902, 1.0),
        // Landcover greens are opaque: they cover whole tiles (a tile can be entirely
        // forest/grass), and a translucent green over the near-white `land` base reads
        // as a washed, pale fill - and does so per-whole-tile, so adjacent tiles jump
        // in tone. Opaque keeps the green saturated and consistent.
        wood: SIMD4<Float>(0.560, 0.760, 0.480, 1.0),
        grass: SIMD4<Float>(0.700, 0.840, 0.540, 1.0),
        farmland: SIMD4<Float>(0.800, 0.860, 0.580, 1.0),
        ice: SIMD4<Float>(0.925, 0.949, 0.973, 1.0),
        sand: SIMD4<Float>(0.945, 0.914, 0.784, 1.0),
        // Wetland/bog covers huge areas in Russia's lowlands; a near-grey tint made
        // whole regions read as desaturated. A muted green reads as the vegetation it is.
        wetland: SIMD4<Float>(0.690, 0.808, 0.639, 1.0),
        park: SIMD4<Float>(0.804, 0.890, 0.761, 1.0),
        residential: SIMD4<Float>(0.929, 0.922, 0.906, 1.0),
        industrial: SIMD4<Float>(0.906, 0.894, 0.878, 1.0),
        boundary: SIMD4<Float>(0.52, 0.15, 0.72, 0.9),
        aeroway: SIMD4<Float>(0.886, 0.882, 0.902, 1.0),
        roads: .immersiveMapTilesDefault
    )
}

public extension ImmersiveMapTilesDefaultMapStyleConfiguration.RoadLayerStyles {
    static let immersiveMapTilesDefault = ImmersiveMapTilesDefaultMapStyleConfiguration.RoadLayerStyles(
        motorway: SIMD4<Float>(0.984, 0.792, 0.549, 1.0),
        trunk: SIMD4<Float>(0.984, 0.843, 0.604, 1.0),
        primary: SIMD4<Float>(0.992, 0.898, 0.663, 1.0),
        secondary: SIMD4<Float>(1.0, 0.961, 0.749, 1.0),
        tertiary: SIMD4<Float>(1.0, 0.988, 0.851, 1.0),
        minor: SIMD4<Float>(0.855, 0.855, 0.870, 1.0),
        service: SIMD4<Float>(0.886, 0.886, 0.898, 1.0),
        path: SIMD4<Float>(0.847, 0.816, 0.757, 1.0),
        rail: SIMD4<Float>(0.702, 0.702, 0.722, 1.0),
        casing: SIMD4<Float>(0.596, 0.596, 0.627, 0.95)
    )
}

public extension ImmersiveMapTilesDefaultMapStyleConfiguration.FeatureStyles {
    static let immersiveMapTilesDefault = ImmersiveMapTilesDefaultMapStyleConfiguration.FeatureStyles(
        buildingFillColor: SIMD4<Float>(0.859, 0.835, 0.796, 1.0)
    )
}

public extension ImmersiveMapTilesDefaultMapStyleConfiguration.LabelStyles {
    static let immersiveMapTilesDefault = ImmersiveMapTilesDefaultMapStyleConfiguration.LabelStyles(
        city: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance(
            fillColor: SIMD3<Float>(0.20, 0.20, 0.22), strokeColor: SIMD3<Float>(1, 1, 1),
            strokeWidthPx: 4.6, sizePx: 30, weight: .bold),
        town: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance(
            fillColor: SIMD3<Float>(0.30, 0.30, 0.32), strokeColor: SIMD3<Float>(1, 1, 1),
            strokeWidthPx: 3.8, sizePx: 22, weight: .thin),
        country: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance(
            fillColor: SIMD3<Float>(0.28, 0.27, 0.33), strokeColor: SIMD3<Float>(1, 1, 1),
            strokeWidthPx: 4.2, sizePx: 26, weight: .bold),
        poi: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance(
            fillColor: SIMD3<Float>(0.40, 0.42, 0.40), strokeColor: SIMD3<Float>(1, 1, 1),
            strokeWidthPx: 3.6, sizePx: 16, weight: .thin),
        water: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance(
            fillColor: SIMD3<Float>(0.24, 0.44, 0.68), strokeColor: SIMD3<Float>(1, 1, 1),
            strokeWidthPx: 3.2, sizePx: 19, weight: .thin),
        road: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance(
            fillColor: SIMD3<Float>(0.30, 0.30, 0.30), strokeColor: SIMD3<Float>(1, 1, 1),
            strokeWidthPx: 3.6, sizePx: 34, weight: .bold)
    )
}
