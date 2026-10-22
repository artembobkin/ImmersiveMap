// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

public extension ProtomapsBasemapTheme {
    /// The night palette: the same map in the dark, the land a deep
    /// blue-grey, the water a deep navy, the greens and the fields of the
    /// day's palette and the biomes of the globe sunk into the night at a
    /// fifth of their light with a blue cast, the roads a warm grey over
    /// the dark land and the overview's highways an amber net, the
    /// buildings a shade above the land, and every label a light grey on
    /// a black halo, graded as the day's greys are, never white: a white
    /// name on a dark map reads as a lamp. The slopes shade by the moon: a deeper shadow and a cool,
    /// faint highlight. Every plate keeps its colour, sunk to the night's
    /// light (`sunkPlate`): the route signs their countries' colours and
    /// the POI icons their categories', since a white or a bright plate is
    /// a lamp on a dark map. The road metrics and the label visibility
    /// are the day's.
    ///
    /// The globe is the day's: the night is the map's, not the planet's,
    /// so the ground of the globe's view wears the day's palette
    /// (`globeLayers`) and its names the day's lettering (`globeLabels`)
    /// under the globe's own sun, and the night comes in with the plane's
    /// air at the end of the unroll, with the sky, the fog and the asphalt
    /// of the roads.
    ///
    /// The map's air, the sky, the horizon and the ground fog, is a setting
    /// rather than a theme (`ImmersiveMapSettings.FogSettings.night`), so
    /// the map of a night goes on with `ImmersiveMapView.night()`, which
    /// sets both, or with `.mapStyle(.night)` and `.fogSettings(.night)`
    /// one by one.
    static let night: ProtomapsBasemapTheme = {
        /// The day's tone sunk into the night: a fifth of its light with a
        /// blue cast, so a forest stays a greener dark than a field.
        func sunk(_ color: SIMD4<Float>) -> SIMD4<Float> {
            SIMD4<Float>(color.x * 0.22 + 0.03, color.y * 0.22 + 0.04, color.z * 0.22 + 0.07, color.w)
        }
        /// A plate in the night's light: half its day's light with a blue
        /// cast, so a white plate is a grey one and a red plate a dark
        /// red, its hue kept.
        func sunkPlate(_ color: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(color.x * 0.5 + 0.02, color.y * 0.5 + 0.03, color.z * 0.5 + 0.05)
        }
        /// A route sign in the night's light: the plate, its edge and its
        /// band sunk (`sunkPlate`), the edge a step further so it does not
        /// ring the plate, and a light number dimmed to a grey, a dark one
        /// as it is.
        func sunkSign(_ sign: RouteShieldAppearance) -> RouteShieldAppearance {
            func number(_ color: SIMD3<Float>) -> SIMD3<Float> {
                (color.x + color.y + color.z) > 1.5 ? color * 0.74 : color
            }
            var sign = sign
            sign.fillColor = sunkPlate(sign.fillColor)
            sign.borderColor = sunkPlate(sign.borderColor) * 0.85
            sign.headerColor = sign.headerColor.map(sunkPlate)
            sign.textColor = number(sign.textColor)
            return sign
        }
        return ProtomapsBasemapTheme.default
            .layers { layers in
                layers.land = SIMD4<Float>(0.09, 0.10, 0.13, 1)
                layers.water = SIMD4<Float>(0.04, 0.09, 0.20, 1)
                layers.wood = SIMD4<Float>(0.06, 0.14, 0.11, 1)
                layers.grass = SIMD4<Float>(0.08, 0.16, 0.12, 1)
                layers.farmland = SIMD4<Float>(0.10, 0.14, 0.10, 1)
                layers.wetland = SIMD4<Float>(0.07, 0.14, 0.13, 1)
                layers.sand = SIMD4<Float>(0.16, 0.15, 0.13, 1)
                layers.ice = SIMD4<Float>(0.30, 0.32, 0.36, 1)
                layers.park = SIMD4<Float>(0.08, 0.17, 0.13, 1)
                layers.residential = SIMD4<Float>(0.12, 0.12, 0.15, 1)
                layers.industrial = SIMD4<Float>(0.14, 0.13, 0.15, 1)
                layers.aeroway = SIMD4<Float>(0.16, 0.16, 0.19, 1)
                layers.boundary = SIMD4<Float>(0.58, 0.36, 0.78, 0.9)
                let base = SIMD4<Float>(0.42, 0.40, 0.36, 1)
                let minor = SIMD4<Float>(0.24, 0.24, 0.28, 1)
                layers.roads = RoadLayerStyles(motorway: base, trunk: base, primary: base,
                                               secondary: minor, tertiary: minor, minor: minor,
                                               service: minor, path: minor, rail: minor,
                                               casing: SIMD4<Float>(0.06, 0.06, 0.08, 0.95),
                                               marking: SIMD4<Float>(0.55, 0.53, 0.48, 1))
                // The globe's overview in the dark: every biome and cover
                // tone sunk from the day's, so the continents keep their
                // climates in the night, and the highways an amber net.
                let day = BiomeStyles.default
                layers.biomes = BiomeStyles(tropicalMoistForest: sunk(day.tropicalMoistForest),
                                            tropicalDryForest: sunk(day.tropicalDryForest),
                                            tropicalConiferForest: sunk(day.tropicalConiferForest),
                                            temperateBroadleafForest: sunk(day.temperateBroadleafForest),
                                            temperateConiferForest: sunk(day.temperateConiferForest),
                                            borealForest: sunk(day.borealForest),
                                            tropicalGrassland: sunk(day.tropicalGrassland),
                                            temperateGrassland: sunk(day.temperateGrassland),
                                            floodedGrassland: sunk(day.floodedGrassland),
                                            montaneGrassland: sunk(day.montaneGrassland),
                                            tundra: sunk(day.tundra),
                                            mediterraneanScrub: sunk(day.mediterraneanScrub),
                                            desert: sunk(day.desert),
                                            mangrove: sunk(day.mangrove),
                                            forestCover: sunk(day.forestCover),
                                            farmlandCover: sunk(day.farmlandCover),
                                            barrenCover: sunk(day.barrenCover),
                                            maximumTileZoom: day.maximumTileZoom,
                                            coverMinimumTileZoom: day.coverMinimumTileZoom)
                layers.overviewRoads.major = SIMD4<Float>(0.72, 0.58, 0.26, 1)
                layers.overviewRoads.minor = SIMD4<Float>(0.42, 0.39, 0.30, 1)
                layers.trees.palette = .night
            }
            .apply { theme in
                theme.globeLayers = ProtomapsBasemapTheme.default.layers
                theme.globeLabels = ProtomapsBasemapTheme.default.labels
            }
            .routeShields { shields in
                shields.rules = shields.rules.map { rule in
                    var rule = rule
                    rule.appearance = rule.appearance.map(sunkSign)
                    return rule
                }
                shields.fallback = shields.fallback.map(sunkSign)
            }
            .features { features in
                features.buildingFillColor = SIMD4<Float>(0.18, 0.19, 0.23, 1)
            }
            .labels { labels in
                // The day's greys mirrored into the dark, graded as the
                // day's are: the cities the lightest, the villages and the
                // lettering of the lands a step dimmer, none of them white.
                // A white name on a dark map reads as a lamp, not as ink.
                let stroke = SIMD3<Float>(0.02, 0.03, 0.06)
                let fills: [(WritableKeyPath<LabelStyles, LabelAppearance>, SIMD3<Float>)] = [
                    (\.city, SIMD3<Float>(0.84, 0.86, 0.92)),
                    (\.town, SIMD3<Float>(0.74, 0.77, 0.84)),
                    (\.district, SIMD3<Float>(0.60, 0.63, 0.71)),
                    (\.country, SIMD3<Float>(0.66, 0.68, 0.78)),
                    (\.region, SIMD3<Float>(0.60, 0.62, 0.72)),
                    (\.poi, SIMD3<Float>(0.62, 0.65, 0.73)),
                    (\.road, SIMD3<Float>(0.60, 0.62, 0.68)),
                    (\.water, SIMD3<Float>(0.42, 0.58, 0.84)),
                ]
                for (keyPath, fill) in fills {
                    labels[keyPath: keyPath].fillColor = fill
                    labels[keyPath: keyPath].strokeColor = stroke
                }
                // The POI plates in their categories' colours, sunk.
                labels.poiCategories = labels.poiCategories.map(sunkPlate)
            }
            .apply { theme in
                theme.hillshade.shadowColor = SIMD4<Float>(0.0, 0.01, 0.04, 0.45)
                theme.hillshade.highlightColor = SIMD4<Float>(0.55, 0.65, 0.95, 0.12)
            }
    }()
}

public extension ProtomapsBasemapMapStyle {
    /// The built-in style in the night palette (`ProtomapsBasemapTheme.night`).
    static let night = ProtomapsBasemapMapStyle(theme: .night)
}

extension ImmersiveMapMapStyle where Self == ProtomapsBasemapMapStyle {
    /// The night palette, so `.mapStyle(.night)` reads without the type name.
    public static var night: ProtomapsBasemapMapStyle { ProtomapsBasemapMapStyle.night }
}
