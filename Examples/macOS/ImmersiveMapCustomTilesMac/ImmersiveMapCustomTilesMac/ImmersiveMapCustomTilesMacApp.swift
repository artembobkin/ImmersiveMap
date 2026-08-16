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
    @State private var provider = Self.makeProvider(urlText: Self.defaultTileBaseURL.absoluteString,
                                                    apiKey: "")

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
    /// chosen in plain Swift before the view is handed to SwiftUI.
    ///
    /// The tile source is always the one configured above; only the style is
    /// toggled, so the comparison is like for like: the same bytes drawn by the
    /// hand-written style versus by the built-in one.
    private var mapView: ImmersiveMapView {
        let base = ImmersiveMapView()
            .camera(camera, position: Self.overview)
            .tileProvider(provider)
        guard usesCustomStyle else {
            return base
        }
        return base.mapStyle(VectorTileMapStyle(style: DemoTileStyle()))
    }

    /// A tile source is a URL plus how credentials travel. The URL field takes
    /// either form: a base URL, whose TileJSON endpoint the loader discovers
    /// (falling back to `tileBaseURL/{z}/{x}/{y}.mvt` until it resolves), or a
    /// full template with `{x}`/`{y}`/`{z}` placeholders such as
    /// `https://tiles.com/{x}/{y}/{z}?apiKey=xxx`, which is used verbatim.
    /// (For an OpenMapTiles-schema endpoint drawn by the built-in style, the
    /// one-line `.tileURLTemplate(_:headers:)` view modifier does all of this
    /// without a provider; this example builds one to also swap the style.)
    private static func makeProvider(urlText: String, apiKey: String) -> VectorTileProvider {
        // Credentials travel as request headers on the tile source (or inside
        // the template's query string). Empty means anonymous.
        let headers = apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
        var tileSource: ImmersiveMapTileSource
        if urlText.contains("{x}") {
            tileSource = .template(urlText)
        } else {
            let tileBaseURL = URL(string: urlText) ?? Self.defaultTileBaseURL
            tileSource = ImmersiveMapTileSource(
                tileBaseURL: tileBaseURL,
                tileJSONURL: tileBaseURL.deletingLastPathComponent()
                    .appendingPathComponent("tiles.json"))
        }
        tileSource = tileSource.headers(headers)

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
            // Required by the data licence, and it has to name what is actually
            // being served. This example defaults to the hosted endpoint, an
            // OpenStreetMap planet in the OpenMapTiles schema, so the badge
            // credits both; `.openStreetMap` alone would under-credit it. Point
            // the URL field at your own source and this string becomes yours to
            // get right, see ATTRIBUTION.md.
            attribution: ImmersiveMapAttribution(
                title: "© OpenStreetMap © OpenMapTiles",
                copyright: "",
                linkURL: URL(string: "https://www.openstreetmap.org/copyright")))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("https://host/tiles or https://host/{x}/{y}/{z}", text: $tileBaseURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            SecureField("api key (optional)", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button("Apply") {
                applyTileSource()
            }
            .disabled(tileBaseURLText.isEmpty)

            Divider().frame(height: 20)

            Toggle("Custom style", isOn: $usesCustomStyle)
                .toggleStyle(.switch)
                .help("Off draws the same tiles with the built-in style")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Rebuilding the provider changes its `configurationFingerprint`, which is
    /// what keeps caches of different sources apart: without a fingerprint
    /// change the new source would be served stale tiles from disk.
    private func applyTileSource() {
        provider = Self.makeProvider(urlText: tileBaseURLText, apiKey: apiKey)
    }

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 48.8566,
        longitudeDegrees: 2.3522,
        zoom: 11.5,
        bearing: 0,
        pitch: 0.2
    )
}
