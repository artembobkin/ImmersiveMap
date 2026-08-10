// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// The dark palette from the `ImmersiveMapSettingsMac` example, packaged as the
/// look of this post.
///
/// It is two separate things that both read as "dark theme". The palette proper
/// is an `ImmersiveMapTilesMapStyle` built from a configuration: those colors
/// are baked into prepared tiles and into their disk-cache identity, so the map
/// is dark from the first tile rather than tinted afterwards. The engine-level
/// colors that belong to no tile (the flat background, the sphere under the
/// tiles, the color painted where nothing has loaded yet) live in
/// `ImmersiveMapSettings` and are set alongside it. Miss the second half and
/// the descent starts with a white globe and loads dark squares onto it.
enum BerlinNightTheme {
    /// The land color, reused wherever a surface has to disappear into the map.
    private static let land = SIMD4<Float>(0.09, 0.10, 0.13, 1)

    static let mapStyle = ImmersiveMapTilesMapStyle(configuration: configuration)

    private static var configuration: ImmersiveMapTilesDefaultMapStyleConfiguration {
        ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .layers { layers in
                layers.land = land
                layers.water = SIMD4<Float>(0.04, 0.09, 0.20, 1)
                layers.wood = SIMD4<Float>(0.06, 0.14, 0.11, 1)
                layers.grass = SIMD4<Float>(0.08, 0.16, 0.12, 1)
                layers.farmland = SIMD4<Float>(0.10, 0.14, 0.10, 1)
                layers.wetland = SIMD4<Float>(0.07, 0.14, 0.13, 1)
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
            .globalLandcover { landcover in
                landcover.land = SIMD4<Float>(0.10, 0.12, 0.14, 1)
                landcover.water = SIMD4<Float>(0.03, 0.07, 0.16, 1)
                landcover.forest = SIMD4<Float>(0.07, 0.14, 0.11, 1)
                landcover.grass = SIMD4<Float>(0.10, 0.15, 0.11, 1)
                landcover.crop = SIMD4<Float>(0.12, 0.14, 0.10, 1)
                landcover.barren = SIMD4<Float>(0.16, 0.15, 0.13, 1)
                landcover.wetland = SIMD4<Float>(0.08, 0.14, 0.13, 1)
                landcover.snow = SIMD4<Float>(0.30, 0.32, 0.36, 1)
            }
    }

    /// The colors the palette cannot carry, because no tile contains them.
    static var style: ImmersiveMapSettings.StyleSettings {
        var style = ImmersiveMapSettings.default.style
        style.baseColors.tileBackground = land
        style.baseColors.globeBackground = SIMD4<Double>(0.02, 0.03, 0.07, 1.0)
        // Depth-correct buildings rather than the default translucent
        // composite: the last third of the descent is spent among them.
        style.buildingExtrusionMode = .solid
        return style
    }

    static var scene: ImmersiveMapSettings.SceneSettings {
        var scene = ImmersiveMapSettings.default.scene
        // Painted where no tile has arrived yet. It has to match the palette's
        // land color, or loading reads as pale holes punched in the map.
        scene.mapClearColor = SIMD4<Double>(0.09, 0.10, 0.13, 1.0)
        // A fixed instant instead of the wall clock, so a render started at
        // any hour puts the terminator in the same place and two takes cut
        // together. Midsummer late morning UTC: Europe is on the lit side and
        // the globe opens with Berlin facing the camera in daylight.
        scene.earth.timeMode = .fixed(Date(timeIntervalSince1970: 1_782_039_600))
        // No sun disk: a bright flare crossing the frame fights a dark post.
        scene.earth.sun.isEnabled = false
        // The dark palette leaves little to dim, so the night side is lifted
        // to keep the coastline readable while the camera is still up high.
        scene.earth.nightSideBrightness = 0.55
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
                                    casing: SIMD4<Float>) -> ImmersiveMapTilesDefaultMapStyleConfiguration.RoadLayerStyles {
        ImmersiveMapTilesDefaultMapStyleConfiguration.RoadLayerStyles(motorway: base,
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

    private static func tint(_ labels: inout ImmersiveMapTilesDefaultMapStyleConfiguration.LabelStyles,
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
