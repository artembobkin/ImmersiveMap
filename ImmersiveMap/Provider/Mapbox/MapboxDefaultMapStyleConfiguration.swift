// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

public struct MapboxDefaultMapStyleConfiguration: Equatable, Sendable {
    public struct LabelAppearance: Equatable, Sendable {
        public var fillColor: SIMD3<Float>
        public var strokeColor: SIMD3<Float>
        public var strokeWidthPx: Float
        public var weight: LabelFontWeight

        public init(fillColor: SIMD3<Float>,
                    strokeColor: SIMD3<Float>,
                    strokeWidthPx: Float,
                    weight: LabelFontWeight) {
            self.fillColor = fillColor
            self.strokeColor = strokeColor
            self.strokeWidthPx = strokeWidthPx
            self.weight = weight
        }
    }

    public struct LabelStyles: Equatable, Sendable {
        public var city: LabelAppearance
        public var smallSettlement: LabelAppearance
        public var district: LabelAppearance
        public var capital: LabelAppearance
        public var nationalCapital: LabelAppearance
        public var poi: LabelAppearance
        public var landmark: LabelAppearance
        public var road: LabelAppearance
        public var water: LabelAppearance
        public var continent: LabelAppearance
        public var houseNumber: LabelAppearance

        public init(city: LabelAppearance,
                    smallSettlement: LabelAppearance,
                    district: LabelAppearance,
                    capital: LabelAppearance,
                    nationalCapital: LabelAppearance,
                    poi: LabelAppearance,
                    landmark: LabelAppearance,
                    road: LabelAppearance,
                    water: LabelAppearance,
                    continent: LabelAppearance,
                    houseNumber: LabelAppearance) {
            self.city = city
            self.smallSettlement = smallSettlement
            self.district = district
            self.capital = capital
            self.nationalCapital = nationalCapital
            self.poi = poi
            self.landmark = landmark
            self.road = road
            self.water = water
            self.continent = continent
            self.houseNumber = houseNumber
        }
    }

    public struct RoadLayerStyles: Equatable, Sendable {
        public var major: SIMD4<Float>
        public var minor: SIMD4<Float>
        public var pedestrian: SIMD4<Float>
        public var motorway: SIMD4<Float>
        public var motorwayLink: SIMD4<Float>
        public var trunk: SIMD4<Float>
        public var trunkLink: SIMD4<Float>
        public var primaryLink: SIMD4<Float>
        public var secondaryLink: SIMD4<Float>
        public var tertiaryLink: SIMD4<Float>
        public var residential: SIMD4<Float>
        public var livingStreet: SIMD4<Float>
        public var unclassified: SIMD4<Float>
        public var streetLimited: SIMD4<Float>
        public var path: SIMD4<Float>
        public var cycleway: SIMD4<Float>
        public var track: SIMD4<Float>
        public var stepsBase: SIMD4<Float>
        public var steps: SIMD4<Float>
        public var footway: SIMD4<Float>
        public var sidewalk: SIMD4<Float>
        public var trail: SIMD4<Float>
        public var crossing: SIMD4<Float>
        public var minorLocal: SIMD4<Float>
        public var misc: SIMD4<Float>

        public init(major: SIMD4<Float>,
                    minor: SIMD4<Float>,
                    pedestrian: SIMD4<Float>,
                    motorway: SIMD4<Float>,
                    motorwayLink: SIMD4<Float>,
                    trunk: SIMD4<Float>,
                    trunkLink: SIMD4<Float>,
                    primaryLink: SIMD4<Float>,
                    secondaryLink: SIMD4<Float>,
                    tertiaryLink: SIMD4<Float>,
                    residential: SIMD4<Float>,
                    livingStreet: SIMD4<Float>,
                    unclassified: SIMD4<Float>,
                    streetLimited: SIMD4<Float>,
                    path: SIMD4<Float>,
                    cycleway: SIMD4<Float>,
                    track: SIMD4<Float>,
                    stepsBase: SIMD4<Float>,
                    steps: SIMD4<Float>,
                    footway: SIMD4<Float>,
                    sidewalk: SIMD4<Float>,
                    trail: SIMD4<Float>,
                    crossing: SIMD4<Float>,
                    minorLocal: SIMD4<Float>,
                    misc: SIMD4<Float>) {
            self.major = major
            self.minor = minor
            self.pedestrian = pedestrian
            self.motorway = motorway
            self.motorwayLink = motorwayLink
            self.trunk = trunk
            self.trunkLink = trunkLink
            self.primaryLink = primaryLink
            self.secondaryLink = secondaryLink
            self.tertiaryLink = tertiaryLink
            self.residential = residential
            self.livingStreet = livingStreet
            self.unclassified = unclassified
            self.streetLimited = streetLimited
            self.path = path
            self.cycleway = cycleway
            self.track = track
            self.stepsBase = stepsBase
            self.steps = steps
            self.footway = footway
            self.sidewalk = sidewalk
            self.trail = trail
            self.crossing = crossing
            self.minorLocal = minorLocal
            self.misc = misc
        }
    }

    public struct RailwayLayerStyles: Equatable, Sendable {
        public var border: SIMD4<Float>
        public var fill: SIMD4<Float>
        public var sleepers: SIMD4<Float>

        public init(border: SIMD4<Float>,
                    fill: SIMD4<Float>,
                    sleepers: SIMD4<Float>) {
            self.border = border
            self.fill = fill
            self.sleepers = sleepers
        }
    }

    public struct LayerStyles: Equatable, Sendable {
        public var adminBoundary: SIMD4<Float>
        public var adminLevel1: SIMD4<Float>
        public var water: SIMD4<Float>
        public var river: SIMD4<Float>
        public var forest: SIMD4<Float>
        public var scrub: SIMD4<Float>
        public var grass: SIMD4<Float>
        public var crop: SIMD4<Float>
        public var snow: SIMD4<Float>
        public var hillshadeShadow: SIMD4<Float>
        public var hillshadeHighlight: SIMD4<Float>
        public var contour: SIMD4<Float>
        public var roads: RoadLayerStyles
        public var park: SIMD4<Float>
        public var residential: SIMD4<Float>
        public var industrial: SIMD4<Float>
        public var farmland: SIMD4<Float>
        public var railway: RailwayLayerStyles
        public var aeroway: SIMD4<Float>

        public init(adminBoundary: SIMD4<Float>,
                    adminLevel1: SIMD4<Float>,
                    water: SIMD4<Float>,
                    river: SIMD4<Float>,
                    forest: SIMD4<Float>,
                    scrub: SIMD4<Float>,
                    grass: SIMD4<Float>,
                    crop: SIMD4<Float>,
                    snow: SIMD4<Float>,
                    hillshadeShadow: SIMD4<Float>,
                    hillshadeHighlight: SIMD4<Float>,
                    contour: SIMD4<Float>,
                    roads: RoadLayerStyles,
                    park: SIMD4<Float>,
                    residential: SIMD4<Float>,
                    industrial: SIMD4<Float>,
                    farmland: SIMD4<Float>,
                    railway: RailwayLayerStyles,
                    aeroway: SIMD4<Float>) {
            self.adminBoundary = adminBoundary
            self.adminLevel1 = adminLevel1
            self.water = water
            self.river = river
            self.forest = forest
            self.scrub = scrub
            self.grass = grass
            self.crop = crop
            self.snow = snow
            self.hillshadeShadow = hillshadeShadow
            self.hillshadeHighlight = hillshadeHighlight
            self.contour = contour
            self.roads = roads
            self.park = park
            self.residential = residential
            self.industrial = industrial
            self.farmland = farmland
            self.railway = railway
            self.aeroway = aeroway
        }
    }

    public struct FeatureStyles: Equatable, Sendable {
        public var buildingFillColor: SIMD4<Float>

        public init(buildingFillColor: SIMD4<Float>) {
            self.buildingFillColor = buildingFillColor
        }
    }

    public var labels: LabelStyles
    public var layers: LayerStyles
    public var features: FeatureStyles

    public init(labels: LabelStyles = .standard,
                layers: LayerStyles = .standard,
                features: FeatureStyles = .standard) {
        self.labels = labels
        self.layers = layers
        self.features = features
    }

    public static let mapboxDefault = MapboxDefaultMapStyleConfiguration()

    public func labels(_ update: (inout LabelStyles) -> Void) -> MapboxDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.labels)
        return copy
    }

    public func layers(_ update: (inout LayerStyles) -> Void) -> MapboxDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.layers)
        return copy
    }

    public func features(_ update: (inout FeatureStyles) -> Void) -> MapboxDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.features)
        return copy
    }

    var cacheFingerprint: UInt32 {
        var hash: UInt64 = 1469598103934665603
        mix(labels.city, into: &hash)
        mix(labels.smallSettlement, into: &hash)
        mix(labels.district, into: &hash)
        mix(labels.capital, into: &hash)
        mix(labels.nationalCapital, into: &hash)
        mix(labels.poi, into: &hash)
        mix(labels.landmark, into: &hash)
        mix(labels.road, into: &hash)
        mix(labels.water, into: &hash)
        mix(labels.continent, into: &hash)
        mix(labels.houseNumber, into: &hash)
        mix(layers, into: &hash)
        mix(features.buildingFillColor, into: &hash)
        return UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
    }

    private func mix(_ appearance: LabelAppearance, into hash: inout UInt64) {
        mix(appearance.fillColor, into: &hash)
        mix(appearance.strokeColor, into: &hash)
        mix(appearance.strokeWidthPx, into: &hash)
        mix(UInt64(appearance.weight.rawValue), into: &hash)
    }

    private func mix(_ layers: LayerStyles, into hash: inout UInt64) {
        mix(layers.adminBoundary, into: &hash)
        mix(layers.adminLevel1, into: &hash)
        mix(layers.water, into: &hash)
        mix(layers.river, into: &hash)
        mix(layers.forest, into: &hash)
        mix(layers.scrub, into: &hash)
        mix(layers.grass, into: &hash)
        mix(layers.crop, into: &hash)
        mix(layers.snow, into: &hash)
        mix(layers.hillshadeShadow, into: &hash)
        mix(layers.hillshadeHighlight, into: &hash)
        mix(layers.contour, into: &hash)
        mix(layers.roads, into: &hash)
        mix(layers.park, into: &hash)
        mix(layers.residential, into: &hash)
        mix(layers.industrial, into: &hash)
        mix(layers.farmland, into: &hash)
        mix(layers.railway.border, into: &hash)
        mix(layers.railway.fill, into: &hash)
        mix(layers.railway.sleepers, into: &hash)
        mix(layers.aeroway, into: &hash)
    }

    private func mix(_ roads: RoadLayerStyles, into hash: inout UInt64) {
        mix(roads.major, into: &hash)
        mix(roads.minor, into: &hash)
        mix(roads.pedestrian, into: &hash)
        mix(roads.motorway, into: &hash)
        mix(roads.motorwayLink, into: &hash)
        mix(roads.trunk, into: &hash)
        mix(roads.trunkLink, into: &hash)
        mix(roads.primaryLink, into: &hash)
        mix(roads.secondaryLink, into: &hash)
        mix(roads.tertiaryLink, into: &hash)
        mix(roads.residential, into: &hash)
        mix(roads.livingStreet, into: &hash)
        mix(roads.unclassified, into: &hash)
        mix(roads.streetLimited, into: &hash)
        mix(roads.path, into: &hash)
        mix(roads.cycleway, into: &hash)
        mix(roads.track, into: &hash)
        mix(roads.stepsBase, into: &hash)
        mix(roads.steps, into: &hash)
        mix(roads.footway, into: &hash)
        mix(roads.sidewalk, into: &hash)
        mix(roads.trail, into: &hash)
        mix(roads.crossing, into: &hash)
        mix(roads.minorLocal, into: &hash)
        mix(roads.misc, into: &hash)
    }

    private func mix(_ value: SIMD3<Float>, into hash: inout UInt64) {
        mix(value.x, into: &hash)
        mix(value.y, into: &hash)
        mix(value.z, into: &hash)
    }

    private func mix(_ value: SIMD4<Float>, into hash: inout UInt64) {
        mix(value.x, into: &hash)
        mix(value.y, into: &hash)
        mix(value.z, into: &hash)
        mix(value.w, into: &hash)
    }

    private func mix(_ value: Float, into hash: inout UInt64) {
        let normalized = value == 0 ? 0 : value
        mix(UInt64(normalized.bitPattern), into: &hash)
    }

    private func mix(_ value: UInt64, into hash: inout UInt64) {
        hash ^= value
        hash &*= 1099511628211
    }
}

public extension MapboxDefaultMapStyleConfiguration.LabelStyles {
    static let standard = MapboxDefaultMapStyleConfiguration.LabelStyles(
        city: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.38, 0.37, 0.35),
                                                            strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                            strokeWidthPx: 5.4,
                                                            weight: .thin),
        smallSettlement: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.38, 0.37, 0.35),
                                                                       strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                                       strokeWidthPx: 5.4,
                                                                       weight: .thin),
        district: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.44, 0.43, 0.41),
                                                                strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                                strokeWidthPx: 2.7,
                                                                weight: .thin),
        capital: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.30, 0.29, 0.27),
                                                               strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                               strokeWidthPx: 5.4,
                                                               weight: .thin),
        nationalCapital: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.30, 0.29, 0.27),
                                                                       strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                                       strokeWidthPx: 7.8,
                                                                       weight: .bold),
        poi: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                                           strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                           strokeWidthPx: 7.2,
                                                           weight: .thin),
        landmark: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                                                strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                                strokeWidthPx: 7.8,
                                                                weight: .thin),
        road: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                                            strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                            strokeWidthPx: 2.6,
                                                            weight: .thin),
        water: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.10, 0.28, 0.72),
                                                             strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                             strokeWidthPx: 5.4,
                                                             weight: .bold),
        continent: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.35, 0.35, 0.35),
                                                                 strokeColor: SIMD3<Float>(0.35, 0.35, 0.35),
                                                                 strokeWidthPx: 0.0,
                                                                 weight: .bold),
        houseNumber: MapboxDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.47, 0.46, 0.44),
                                                                   strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
                                                                   strokeWidthPx: 8.1,
                                                                   weight: .thin)
    )
}

public extension MapboxDefaultMapStyleConfiguration.LayerStyles {
    static let standard = MapboxDefaultMapStyleConfiguration.LayerStyles(
        adminBoundary: SIMD4<Float>(0.65, 0.65, 0.75, 1.0),
        adminLevel1: SIMD4<Float>(0.45, 0.55, 0.85, 1.0),
        water: SIMD4<Float>(0.3, 0.6, 0.9, 1.0),
        river: SIMD4<Float>(0.2, 0.5, 0.8, 1.0),
        forest: SIMD4<Float>(0.2, 0.6, 0.4, 0.7),
        scrub: SIMD4<Float>(0.42, 0.68, 0.40, 0.64),
        grass: SIMD4<Float>(0.4, 0.7, 0.4, 0.7),
        crop: SIMD4<Float>(0.62, 0.74, 0.42, 0.58),
        snow: SIMD4<Float>(0.96, 0.97, 0.98, 0.86),
        hillshadeShadow: SIMD4<Float>(0.30, 0.36, 0.40, 0.18),
        hillshadeHighlight: SIMD4<Float>(1.0, 1.0, 1.0, 0.16),
        contour: SIMD4<Float>(0.58, 0.60, 0.52, 0.34),
        roads: .standard,
        park: SIMD4<Float>(0.55, 0.75, 0.5, 0.7),
        residential: SIMD4<Float>(0.92, 0.9, 0.85, 0.6),
        industrial: SIMD4<Float>(0.85, 0.82, 0.78, 0.7),
        farmland: SIMD4<Float>(0.86, 0.8, 0.6, 0.6),
        railway: .standard,
        aeroway: SIMD4<Float>(0.88, 0.88, 0.9, 0.9)
    )
}

public extension MapboxDefaultMapStyleConfiguration.RoadLayerStyles {
    static let standard = MapboxDefaultMapStyleConfiguration.RoadLayerStyles(
        major: SIMD4<Float>(0.9, 0.9, 0.9, 1.0),
        minor: SIMD4<Float>(0.7, 0.7, 0.7, 1.0),
        pedestrian: SIMD4<Float>(0.965, 0.965, 0.955, 1.0),
        motorway: SIMD4<Float>(0.93, 0.54, 0.33, 1.0),
        motorwayLink: SIMD4<Float>(0.95, 0.66, 0.39, 1.0),
        trunk: SIMD4<Float>(0.95, 0.68, 0.28, 1.0),
        trunkLink: SIMD4<Float>(0.96, 0.76, 0.40, 1.0),
        primaryLink: SIMD4<Float>(0.90, 0.895, 0.88, 1.0),
        secondaryLink: SIMD4<Float>(0.885, 0.88, 0.865, 1.0),
        tertiaryLink: SIMD4<Float>(0.87, 0.865, 0.85, 1.0),
        residential: SIMD4<Float>(0.82, 0.63, 0.63, 1.0),
        livingStreet: SIMD4<Float>(0.73, 0.63, 0.83, 1.0),
        unclassified: SIMD4<Float>(0.60, 0.67, 0.79, 1.0),
        streetLimited: SIMD4<Float>(0.47, 0.74, 0.82, 1.0),
        path: SIMD4<Float>(0.33, 0.74, 0.56, 1.0),
        cycleway: SIMD4<Float>(0.16, 0.71, 0.74, 1.0),
        track: SIMD4<Float>(0.40, 0.39, 0.31, 1.0),
        stepsBase: SIMD4<Float>(0.94, 0.94, 0.925, 1.0),
        steps: SIMD4<Float>(0.58, 0.56, 0.52, 1.0),
        footway: SIMD4<Float>(0.948, 0.948, 0.936, 1.0),
        sidewalk: SIMD4<Float>(0.985, 0.98, 0.965, 1.0),
        trail: SIMD4<Float>(0.84, 0.85, 0.78, 1.0),
        crossing: SIMD4<Float>(0.94, 0.94, 0.94, 1.0),
        minorLocal: SIMD4<Float>(0.54, 0.72, 0.65, 1.0),
        misc: SIMD4<Float>(0.64, 0.64, 0.64, 1.0)
    )
}

public extension MapboxDefaultMapStyleConfiguration.FeatureStyles {
    static let standard = MapboxDefaultMapStyleConfiguration.FeatureStyles(
        buildingFillColor: SIMD4<Float>(0.94902, 0.92549, 0.890196, 1.0)
    )
}

public extension MapboxDefaultMapStyleConfiguration.RailwayLayerStyles {
    static let standard = MapboxDefaultMapStyleConfiguration.RailwayLayerStyles(
        border: SIMD4<Float>(0.73, 0.81, 0.82, 1.0),
        fill: SIMD4<Float>(0.99, 0.99, 0.99, 1.0),
        sleepers: SIMD4<Float>(0.65, 0.74, 0.75, 1.0)
    )
}
