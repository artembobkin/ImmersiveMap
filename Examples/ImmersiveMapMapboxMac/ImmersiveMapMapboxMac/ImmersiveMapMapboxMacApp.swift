// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapMapboxMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Mapbox") {
            MapboxScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// Rendering Mapbox Vector Tiles instead of the built-in source: attach a
/// `MapboxTileProvider` and the matching `MapboxMapStyle`. The provider decides
/// where tiles come from and how their MVT schema maps onto labels; the style
/// decides how the data is drawn.
///
/// The token is never committed. It is read from the launch environment
/// variable `IMMERSIVE_MAP_MAPBOX_ACCESS_TOKEN` (enabled in this project's
/// scheme with an empty value: paste yours into Edit Scheme), and the field
/// below is the fallback for a quick try.
private struct MapboxScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var token = ProcessInfo.processInfo
        .environment["IMMERSIVE_MAP_MAPBOX_ACCESS_TOKEN"] ?? ""
    @State private var appliedToken = ProcessInfo.processInfo
        .environment["IMMERSIVE_MAP_MAPBOX_ACCESS_TOKEN"] ?? ""
    @State private var tilesetID = MapboxTileProvider.defaultTilesetID
    @State private var usesNightPalette = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if appliedToken.isEmpty {
                missingTokenNotice
            } else {
                ImmersiveMapView()
                    .camera(camera, position: Self.overview)
                    .tileProvider(MapboxTileProvider(accessToken: appliedToken,
                                                     tilesetID: tilesetID))
                    .mapStyle(MapboxMapStyle(configuration: styleConfiguration))
                    .enableCameraUIControls()
                    .ignoresSafeArea()
            }

            controls
                .padding(20)
        }
    }

    /// A public token, a tileset id and a style are all a provider swap needs.
    /// Changing any of them changes the provider's `configurationFingerprint`,
    /// which is what keeps the tile caches of different configurations apart.
    private var styleConfiguration: MapboxDefaultMapStyleConfiguration {
        guard usesNightPalette else {
            return .mapboxDefault
        }
        return MapboxDefaultMapStyleConfiguration.mapboxDefault
            .layers { layers in
                layers.water = SIMD4<Float>(0.04, 0.09, 0.20, 1)
                layers.river = SIMD4<Float>(0.05, 0.11, 0.24, 1)
                layers.forest = SIMD4<Float>(0.06, 0.13, 0.10, 1)
                layers.park = SIMD4<Float>(0.07, 0.15, 0.11, 1)
                layers.residential = SIMD4<Float>(0.11, 0.11, 0.13, 1)
            }
            .features { features in
                features.buildingFillColor = SIMD4<Float>(0.18, 0.19, 0.23, 1)
            }
            .labels { labels in
                labels.city.fillColor = SIMD3<Float>(0.92, 0.94, 1.0)
                labels.city.strokeColor = SIMD3<Float>(0.02, 0.03, 0.06)
                labels.road.fillColor = SIMD3<Float>(0.78, 0.82, 0.92)
                labels.road.strokeColor = SIMD3<Float>(0.02, 0.03, 0.06)
            }
    }

    private var missingTokenNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No Mapbox access token")
                .font(.title3.weight(.semibold))
            Text("""
                 Set IMMERSIVE_MAP_MAPBOX_ACCESS_TOKEN in the scheme's launch \
                 environment, or paste a public token below. Every other example \
                 in this repository runs on the built-in tile source and needs \
                 no token at all.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            SecureField("pk.…", text: $token)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            TextField("tileset id", text: $tilesetID)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            Button("Apply") {
                appliedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Divider().frame(height: 20)

            Toggle("Night palette", isOn: $usesNightPalette)
                .toggleStyle(.switch)
                .disabled(appliedToken.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 48.8566,
        longitudeDegrees: 2.3522,
        zoom: 13.0,
        bearing: 0,
        pitch: 0.4
    )
}
