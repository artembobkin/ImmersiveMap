// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// The dark palette from the `ImmersiveMapSettingsMac` example, packaged as the
/// look of this post: an `ImmersiveMapTilesMapStyle` built from a theme. Its
/// colours are baked into prepared tiles and into their disk-cache identity,
/// so the map is dark from the first tile rather than tinted afterwards, and
/// what no tile paints (the ground where nothing has loaded yet, the polar
/// caps) takes the theme's land, water and ice by itself.
enum BerlinNightTheme {
    /// The land color, reused wherever a surface has to disappear into the map.
    private static let land = SIMD4<Float>(0.09, 0.10, 0.13, 1)

    static let mapStyle = ImmersiveMapTilesMapStyle(theme: configuration)

    private static var configuration: ImmersiveMapTilesTheme {
        ImmersiveMapTilesTheme.default
            .layers { layers in
                layers.land = land
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
                layers.roads = roadsTinted(base: SIMD4<Float>(0.42, 0.40, 0.36, 1),
                                           minor: SIMD4<Float>(0.24, 0.24, 0.28, 1),
                                           casing: SIMD4<Float>(0.06, 0.06, 0.08, 0.95))
            }
            .features { features in
                // Warmer and a shade lighter than the example's flat grey: the
                // Mitte blocks are the subject here, and they have to separate
                // from the streets between them once the camera is down low.
                features.buildingFillColor = SIMD4<Float>(0.22, 0.21, 0.24, 1)
            }
            .labels { labels in
                tint(&labels,
                     fill: SIMD3<Float>(0.92, 0.94, 1.0),
                     stroke: SIMD3<Float>(0.02, 0.03, 0.06))
                labels.water.fillColor = SIMD3<Float>(0.55, 0.72, 0.96)
            }
            .labelVisibility { visibility in
                // POI badges are colored icons: they read as app chrome in
                // footage that is supposed to look like a flight.
                visibility.poiMinimumZoom = 30
            }
    }

    static var scene: ImmersiveMapSettings.SceneSettings {
        var scene = ImmersiveMapSettings.default.scene
        // Low light from the south-east across Mitte. The direction points
        // towards the sun in the flat basis (+X east, +Y north, +Z up), so a
        // shallow Z is a long shadow.
        scene.light.direction = SIMD3<Float>(0.55, -0.62, 0.56)
        scene.shadows.isEnabled = true
        scene.shadows.strength = 0.45
        return scene
    }

    static var labels: ImmersiveMapSettings.LabelSettings {
        var labels = ImmersiveMapSettings.default.labels
        // Berlin's own names rather than the transliterated ones: the post is
        // about the place, and "Museumsinsel" is part of the picture.
        labels.language = ImmersiveMapSettings.LabelLanguage("de")
        // House numbers are noise at the zooms this storyboard ends on.
        labels.houseNumbers.enabled = false
        return labels
    }

    private static func roadsTinted(base: SIMD4<Float>,
                                    minor: SIMD4<Float>,
                                    casing: SIMD4<Float>) -> ImmersiveMapTilesTheme.RoadLayerStyles {
        ImmersiveMapTilesTheme.RoadLayerStyles(motorway: base,
                                                                      trunk: base,
                                                                      primary: base,
                                                                      secondary: minor,
                                                                      tertiary: minor,
                                                                      minor: minor,
                                                                      service: minor,
                                                                      path: minor,
                                                                      rail: minor,
                                                                      casing: casing)
    }

    private static func tint(_ labels: inout ImmersiveMapTilesTheme.LabelStyles,
                             fill: SIMD3<Float>,
                             stroke: SIMD3<Float>) {
        labels.city.fillColor = fill
        labels.city.strokeColor = stroke
        labels.town.fillColor = fill
        labels.town.strokeColor = stroke
        labels.country.fillColor = fill
        labels.country.strokeColor = stroke
        labels.poi.fillColor = fill
        labels.poi.strokeColor = stroke
        labels.water.fillColor = fill
        labels.water.strokeColor = stroke
        labels.road.fillColor = fill
        labels.road.strokeColor = stroke
    }
}
