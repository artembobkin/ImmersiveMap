// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

public struct OpenStreetMapDefaultMapStyleConfiguration: Equatable {
    public struct LabelAppearance: Equatable {
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

    public struct LabelStyles: Equatable {
        public var place: LabelAppearance
        public var poi: LabelAppearance
        public var water: LabelAppearance
        public var road: LabelAppearance
        public var boundary: LabelAppearance

        public init(place: LabelAppearance,
                    poi: LabelAppearance,
                    water: LabelAppearance,
                    road: LabelAppearance,
                    boundary: LabelAppearance) {
            self.place = place
            self.poi = poi
            self.water = water
            self.road = road
            self.boundary = boundary
        }
    }

    public struct RoadLayerStyles: Equatable {
        public var major: SIMD4<Float>
        public var minor: SIMD4<Float>
        public var path: SIMD4<Float>
        public var casing: SIMD4<Float>

        public init(major: SIMD4<Float>,
                    minor: SIMD4<Float>,
                    path: SIMD4<Float>,
                    casing: SIMD4<Float>) {
            self.major = major
            self.minor = minor
            self.path = path
            self.casing = casing
        }
    }

    public struct LayerStyles: Equatable {
        public var land: SIMD4<Float>
        public var water: SIMD4<Float>
        public var park: SIMD4<Float>
        public var forest: SIMD4<Float>
        public var site: SIMD4<Float>
        public var boundary: SIMD4<Float>
        public var roads: RoadLayerStyles

        public init(land: SIMD4<Float>,
                    water: SIMD4<Float>,
                    park: SIMD4<Float>,
                    forest: SIMD4<Float>,
                    site: SIMD4<Float>,
                    boundary: SIMD4<Float>,
                    roads: RoadLayerStyles) {
            self.land = land
            self.water = water
            self.park = park
            self.forest = forest
            self.site = site
            self.boundary = boundary
            self.roads = roads
        }
    }

    public struct FeatureStyles: Equatable {
        public var buildingFillColor: SIMD4<Float>

        public init(buildingFillColor: SIMD4<Float>) {
            self.buildingFillColor = buildingFillColor
        }
    }

    public var labels: LabelStyles
    public var layers: LayerStyles
    public var features: FeatureStyles

    public init(labels: LabelStyles = .osmDefault,
                layers: LayerStyles = .osmDefault,
                features: FeatureStyles = .osmDefault) {
        self.labels = labels
        self.layers = layers
        self.features = features
    }

    public static let osmDefault = OpenStreetMapDefaultMapStyleConfiguration()

    public func labels(_ update: (inout LabelStyles) -> Void) -> OpenStreetMapDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.labels)
        return copy
    }

    public func layers(_ update: (inout LayerStyles) -> Void) -> OpenStreetMapDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.layers)
        return copy
    }

    public func features(_ update: (inout FeatureStyles) -> Void) -> OpenStreetMapDefaultMapStyleConfiguration {
        var copy = self
        update(&copy.features)
        return copy
    }

    var cacheFingerprint: UInt32 {
        var hash: UInt64 = 1469598103934665603
        mix(labels.place, into: &hash)
        mix(labels.poi, into: &hash)
        mix(labels.water, into: &hash)
        mix(labels.road, into: &hash)
        mix(labels.boundary, into: &hash)
        mix(layers.land, into: &hash)
        mix(layers.water, into: &hash)
        mix(layers.park, into: &hash)
        mix(layers.forest, into: &hash)
        mix(layers.site, into: &hash)
        mix(layers.boundary, into: &hash)
        mix(layers.roads.major, into: &hash)
        mix(layers.roads.minor, into: &hash)
        mix(layers.roads.path, into: &hash)
        mix(layers.roads.casing, into: &hash)
        mix(features.buildingFillColor, into: &hash)
        let folded = UInt32(truncatingIfNeeded: hash) ^ UInt32(truncatingIfNeeded: hash >> 32)
        return folded == 0 ? 1 : folded
    }

    private func mix(_ appearance: LabelAppearance, into hash: inout UInt64) {
        mix(appearance.fillColor, into: &hash)
        mix(appearance.strokeColor, into: &hash)
        mix(appearance.strokeWidthPx, into: &hash)
        mix(appearance.sizePx, into: &hash)
        mix(UInt64(appearance.weight.rawValue), into: &hash)
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
        var bits = value == 0 ? Float(0).bitPattern : value.bitPattern
        withUnsafeBytes(of: &bits) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
        }
    }

    private func mix(_ value: UInt64, into hash: inout UInt64) {
        var copy = value
        withUnsafeBytes(of: &copy) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
        }
    }
}

public extension OpenStreetMapDefaultMapStyleConfiguration.LabelStyles {
    static let osmDefault = OpenStreetMapDefaultMapStyleConfiguration.LabelStyles(
        place: OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.34, 0.33, 0.31),
                                                                        strokeColor: SIMD3<Float>(1, 1, 1),
                                                                        strokeWidthPx: 4.2,
                                                                        sizePx: 23,
                                                                        weight: .bold),
        poi: OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.45, 0.44, 0.41),
                                                                      strokeColor: SIMD3<Float>(1, 1, 1),
                                                                      strokeWidthPx: 3.6,
                                                                      sizePx: 16,
                                                                      weight: .thin),
        water: OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.12, 0.32, 0.70),
                                                                        strokeColor: SIMD3<Float>(1, 1, 1),
                                                                        strokeWidthPx: 3.1,
                                                                        sizePx: 18,
                                                                        weight: .thin),
        road: OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.42, 0.41, 0.39),
                                                                       strokeColor: SIMD3<Float>(1, 1, 1),
                                                                       strokeWidthPx: 3.0,
                                                                       sizePx: 30,
                                                                       weight: .thin),
        boundary: OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance(fillColor: SIMD3<Float>(0.42, 0.42, 0.44),
                                                                           strokeColor: SIMD3<Float>(1, 1, 1),
                                                                           strokeWidthPx: 2.6,
                                                                           sizePx: 14,
                                                                           weight: .thin)
    )
}

public extension OpenStreetMapDefaultMapStyleConfiguration.LayerStyles {
    static let osmDefault = OpenStreetMapDefaultMapStyleConfiguration.LayerStyles(
        land: SIMD4<Float>(0.94, 0.94, 0.91, 1.0),
        water: SIMD4<Float>(0.57, 0.72, 0.87, 1.0),
        park: SIMD4<Float>(0.72, 0.83, 0.64, 0.9),
        forest: SIMD4<Float>(0.61, 0.76, 0.58, 0.9),
        site: SIMD4<Float>(0.88, 0.84, 0.76, 0.8),
        boundary: SIMD4<Float>(0.55, 0.55, 0.60, 0.9),
        roads: .osmDefault
    )
}

public extension OpenStreetMapDefaultMapStyleConfiguration.RoadLayerStyles {
    static let osmDefault = OpenStreetMapDefaultMapStyleConfiguration.RoadLayerStyles(
        major: SIMD4<Float>(0.96, 0.91, 0.78, 1.0),
        minor: SIMD4<Float>(0.98, 0.97, 0.93, 1.0),
        path: SIMD4<Float>(0.82, 0.80, 0.74, 1.0),
        casing: SIMD4<Float>(0.78, 0.74, 0.66, 0.9)
    )
}

public extension OpenStreetMapDefaultMapStyleConfiguration.FeatureStyles {
    static let osmDefault = OpenStreetMapDefaultMapStyleConfiguration.FeatureStyles(
        buildingFillColor: SIMD4<Float>(0.86, 0.82, 0.76, 1.0)
    )
}
