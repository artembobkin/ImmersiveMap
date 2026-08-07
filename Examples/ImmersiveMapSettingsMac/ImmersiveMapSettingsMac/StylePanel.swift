// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// Two different things that both look like "appearance".
///
/// The palette is the map style: an `ImmersiveMapTilesMapStyle` built from a
/// configuration, handed to the view instead of the default one. Its colors are
/// baked into prepared tiles and into their disk-cache identity (the
/// configuration's `cacheFingerprint`), so a new palette re-prepares everything.
///
/// The attribution badge is chrome drawn over the map, so it restyles for free.
/// It is also the one piece here that is not a matter of taste: the data
/// license requires the credit to be visible, and hiding the badge only makes
/// sense when the app shows the same credit somewhere else, which is what
/// `isProvidedExternally` declares.
struct StylePanel: View {
    @Binding var settings: ImmersiveMapSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Picker("Palette", selection: paletteSelection) {
                    ForEach(StylePalette.allCases) { palette in
                        Text(palette.title).tag(palette)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Divider().frame(height: 20)

                Toggle("Attribution badge", isOn: $settings.attribution.isVisible)
                    .toggleStyle(.switch)

                Picker("Size", selection: $settings.attribution.size) {
                    ForEach(ImmersiveMapSettings.AttributionSettings.Size.allCases, id: \.self) { size in
                        Text(size.rawValue.capitalized).tag(size)
                    }
                }
                .frame(width: 130)

                Picker("Position", selection: $settings.attribution.position) {
                    ForEach(ImmersiveMapSettings.AttributionSettings.Position.allCases, id: \.self) { position in
                        Text(position.rawValue).tag(position)
                    }
                }
                .frame(width: 190)
            }

            DeferredNote(text: "A palette re-parses every tile; the badge is redrawn with the next frame.")
        }
    }

    /// Read back out of the settings rather than kept in `@State`, so leaving
    /// the section and coming back cannot show a palette the map is not using.
    private var paletteSelection: Binding<StylePalette> {
        Binding(get: { StylePalette.allCases.first { $0.isApplied(to: settings) } ?? .day },
                set: { $0.apply(to: &settings) })
    }
}

/// Three palettes for the built-in tile source. Each one is a
/// `ImmersiveMapTilesDefaultMapStyleConfiguration` built with the `.layers`,
/// `.features` and `.labels` builders, plus the engine-level colors that are
/// not part of any tile: the flat map background and the globe background.
enum StylePalette: String, CaseIterable, Identifiable {
    case day
    case night
    case blueprint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .night: "Night"
        case .blueprint: "Blueprint"
        }
    }

    func apply(to settings: inout ImmersiveMapSettings) {
        settings = settings.mapStyle(mapStyle)
        settings.style.baseColors.tileBackground = tileBackground
        settings.style.baseColors.globeBackground = globeBackground
        settings.scene.mapClearColor = mapClearColor
    }

    /// Map styles compare by their configuration fingerprint, which is what the
    /// disk caches are keyed on as well.
    func isApplied(to settings: ImmersiveMapSettings) -> Bool {
        settings.mapStyle == AnyImmersiveMapMapStyle(mapStyle)
    }

    private var mapStyle: ImmersiveMapTilesMapStyle {
        ImmersiveMapTilesMapStyle(configuration: configuration)
    }

    private var configuration: ImmersiveMapTilesDefaultMapStyleConfiguration {
        switch self {
        case .day:
            return .immersiveMapTilesDefault
        case .night:
            return ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
                .layers { layers in
                    layers.land = SIMD4<Float>(0.09, 0.10, 0.13, 1)
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
                    features.buildingFillColor = SIMD4<Float>(0.18, 0.19, 0.23, 1)
                }
                .labels { labels in
                    tint(&labels,
                         fill: SIMD3<Float>(0.92, 0.94, 1.0),
                         stroke: SIMD3<Float>(0.02, 0.03, 0.06))
                    labels.water.fillColor = SIMD3<Float>(0.55, 0.72, 0.96)
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
        case .blueprint:
            return ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
                .layers { layers in
                    let paper = SIMD4<Float>(0.05, 0.16, 0.38, 1)
                    layers.land = paper
                    layers.water = SIMD4<Float>(0.03, 0.11, 0.30, 1)
                    layers.wood = paper
                    layers.grass = paper
                    layers.farmland = paper
                    layers.wetland = paper
                    layers.park = SIMD4<Float>(0.06, 0.19, 0.43, 1)
                    layers.residential = paper
                    layers.industrial = paper
                    layers.aeroway = SIMD4<Float>(0.08, 0.22, 0.48, 1)
                    layers.boundary = SIMD4<Float>(0.75, 0.86, 1.0, 0.9)
                    layers.roads = roadsTinted(base: SIMD4<Float>(0.72, 0.85, 1.0, 1),
                                               minor: SIMD4<Float>(0.45, 0.62, 0.88, 1),
                                               casing: SIMD4<Float>(0.04, 0.13, 0.32, 0.95))
                }
                .features { features in
                    features.buildingFillColor = SIMD4<Float>(0.10, 0.26, 0.55, 1)
                }
                .labels { labels in
                    tint(&labels,
                         fill: SIMD3<Float>(0.88, 0.94, 1.0),
                         stroke: SIMD3<Float>(0.02, 0.09, 0.24))
                }
                .globalLandcover { landcover in
                    let paper = SIMD4<Float>(0.05, 0.16, 0.38, 1)
                    landcover.land = paper
                    landcover.forest = paper
                    landcover.grass = paper
                    landcover.crop = paper
                    landcover.barren = paper
                    landcover.wetland = paper
                    landcover.water = SIMD4<Float>(0.03, 0.11, 0.30, 1)
                    landcover.snow = SIMD4<Float>(0.22, 0.36, 0.62, 1)
                }
        }
    }

    /// Painted where no tile has arrived yet, so it should match the palette's
    /// land color: otherwise loading reads as white holes punched in the map.
    private var mapClearColor: SIMD4<Double> {
        switch self {
        case .day: SIMD4<Double>(1.0, 1.0, 1.0, 1.0)
        case .night: SIMD4<Double>(0.09, 0.10, 0.13, 1.0)
        case .blueprint: SIMD4<Double>(0.05, 0.16, 0.38, 1.0)
        }
    }

    private var tileBackground: SIMD4<Float> {
        switch self {
        case .day: SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        case .night: SIMD4<Float>(0.09, 0.10, 0.13, 1.0)
        case .blueprint: SIMD4<Float>(0.05, 0.16, 0.38, 1.0)
        }
    }

    /// The sphere under the tiles: visible at globe zooms wherever tiles have
    /// not landed yet.
    private var globeBackground: SIMD4<Double> {
        switch self {
        case .day: SIMD4<Double>(0.0039, 0.0431, 0.0980, 1.0)
        case .night: SIMD4<Double>(0.02, 0.03, 0.07, 1.0)
        case .blueprint: SIMD4<Double>(0.02, 0.08, 0.22, 1.0)
        }
    }

    private func roadsTinted(base: SIMD4<Float>,
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

    private func tint(_ labels: inout ImmersiveMapTilesDefaultMapStyleConfiguration.LabelStyles,
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
