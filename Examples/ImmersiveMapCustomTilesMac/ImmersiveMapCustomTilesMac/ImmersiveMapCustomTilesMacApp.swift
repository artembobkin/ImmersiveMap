// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapCustomTilesMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Custom Tiles") {
            CustomTilesScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// Your own MVT tile source, wired entirely through the public API: a
/// `VectorTileProvider` over an `ImmersiveMapTileSource`, plus a hand-written
/// `ImmersiveMapVectorTileStyle` wrapped in a `VectorTileMapStyle`.
///
/// The URL below points at the project's own public endpoint so the example
/// runs with no account, but nothing here is specific to it: any endpoint that
/// serves `{z}/{x}/{y}.mvt` works the same way. Paste yours into the field.
private struct CustomTilesScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var tileBaseURLText = Self.defaultTileBaseURL.absoluteString
    @State private var apiKey = ""
    @State private var usesCustomStyle = true
    @State private var provider = Self.makeProvider(tileBaseURL: Self.defaultTileBaseURL)

    /// A public OpenMapTiles-schema endpoint, used so the example starts with
    /// something on screen. Replace it with your own.
    private static let defaultTileBaseURL = URL(string: "https://tiles.immersivemap.dev/tiles")!

    var body: some View {
        ZStack(alignment: .bottom) {
            mapView
                .enableCameraUIControls()
                .ignoresSafeArea()

            controls
                .padding(20)
        }
    }

    /// The modifiers are value builders, so the provider and the style can be
    /// chosen in plain Swift before the view is handed to SwiftUI. Without them
    /// the map falls back to the built-in provider and style.
    private var mapView: ImmersiveMapView {
        let base = ImmersiveMapView().camera(camera, position: Self.overview)
        guard usesCustomStyle else {
            return base
        }
        return base
            .tileProvider(provider)
            .mapStyle(VectorTileMapStyle(style: DemoTileStyle()))
            // An optional key for the source, sent as an Authorization
            // Bearer header. Empty means anonymous.
            .apiKey(apiKey.isEmpty ? nil : apiKey)
    }

    /// A tile source is a URL template plus how credentials travel. The
    /// TileJSON endpoint is optional: when present the loader discovers a
    /// versioned, immutable tile URL from it and falls back to
    /// `tileBaseURL/{z}/{x}/{y}.mvt` until it resolves.
    private static func makeProvider(tileBaseURL: URL) -> VectorTileProvider {
        let tileSource = ImmersiveMapTileSource(
            tileBaseURL: tileBaseURL,
            tileJSONURL: tileBaseURL.deletingLastPathComponent()
                .appendingPathComponent("tiles.json"),
            authorization: .bearerHeader)

        return VectorTileProvider(
            id: "demo-openmaptiles",
            cacheNamespace: "demo-openmaptiles",
            tileSource: tileSource,
            // Which MVT properties carry the label text, its rank and its kind.
            labelProfile: ImmersiveMapVectorTileLabelProfile(
                textKeys: ["name:en", "name"],
                rankKeys: ["rank"],
                kindKeys: ["class"],
                pointLabelLayers: ["place"]),
            maximumTileZoomLevel: 14,
            // Required by the data licence: OpenStreetMap data is ODbL.
            attribution: .openStreetMap)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("https://host/tiles", text: $tileBaseURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            SecureField("api key (optional)", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button("Apply") {
                applyTileSource()
            }
            .disabled(URL(string: tileBaseURLText) == nil)

            Divider().frame(height: 20)

            Toggle("Custom style", isOn: $usesCustomStyle)
                .toggleStyle(.switch)
                .help("Off shows the same tiles under the built-in provider and style")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Rebuilding the provider changes its `configurationFingerprint`, which is
    /// what keeps caches of different sources apart: without a fingerprint
    /// change the new source would be served stale tiles from disk.
    private func applyTileSource() {
        guard let url = URL(string: tileBaseURLText) else {
            return
        }
        provider = Self.makeProvider(tileBaseURL: url)
    }

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 48.8566,
        longitudeDegrees: 2.3522,
        zoom: 11.5,
        bearing: 0,
        pitch: 0.2
    )
}
