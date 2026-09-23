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

/// Your own MVT tile source, wired entirely through the public API. The source
/// is one PMTiles archive URL set with `.tileArchive(_:headers:)`. How the
/// bytes are parsed and drawn is configured separately, with a hand-written
/// `ImmersiveMapVectorTileStyle` wrapped in a `VectorTileMapStyle` plus the
/// label profile naming which MVT properties carry label text.
///
/// The URL below points at the project's own public archive so the example
/// runs with no account, but nothing here is specific to it: any archive of
/// MVT tiles on a host that answers range requests works the same way. Paste
/// yours into the field.
private struct CustomTilesScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var archiveText = Self.defaultArchive.absoluteString
    @State private var apiKey = ""
    @State private var appliedArchive = Self.defaultArchive
    @State private var appliedAPIKey = ""
    @State private var usesCustomStyle = true

    /// The public hosted archive, used so the example starts with something
    /// on screen. Replace it with your own.
    private static let defaultArchive = URL(string: "https://tiles.immersivemap.dev/20260922.pmtiles")!

    var body: some View {
        ZStack(alignment: .bottom) {
            mapView
                .enableCameraUIControls()
                .ignoresSafeArea()

            controls
                .padding(20)
        }
    }

    /// The modifiers are value builders, so the source and the style can be
    /// chosen in plain Swift before the view is handed to SwiftUI.
    ///
    /// The tile source is always the applied archive; only the style is
    /// toggled, so the comparison is like for like: the same bytes drawn by
    /// the hand-written style versus by the built-in one.
    private var mapView: ImmersiveMapView {
        // Credentials travel as request headers (or inside the archive URL's
        // query string). Empty means anonymous.
        let headers = appliedAPIKey.isEmpty ? [:] : ["Authorization": "Bearer \(appliedAPIKey)"]
        let base = ImmersiveMapView()
            .camera(camera, position: Self.overview)
            .tileArchive(appliedArchive, headers: headers)
            // Required by the data licence, and it has to name what is
            // actually being served. This example defaults to the hosted
            // archive, an OpenStreetMap planet, so the badge credits
            // OpenStreetMap. Point the URL field at your own source and this
            // string becomes yours to get right, see the README.
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(
                attributionOverride: ImmersiveMapAttribution(
                    title: "© OpenStreetMap",
                    copyright: "",
                    linkURL: URL(string: "https://www.openstreetmap.org/copyright"))))
        guard usesCustomStyle else {
            // The built-in style, stated so the two sides of the toggle read
            // side by side: the hosted archive is Protomaps basemap tiles.
            return base.mapStyle(ProtomapsBasemapMapStyle())
        }
        // The demo rules over the Protomaps reading: the style is this app's,
        // the facts it reads (a road's structure) come from the schema.
        return base.mapStyle(VectorTileMapStyle(style: DemoTileStyle(), schema: ProtomapsBasemapSchema()))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("https://host/planet.pmtiles", text: $archiveText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 330)
            SecureField("api key (optional)", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button("Apply") {
                applyTileSource()
            }
            .disabled(Self.archiveURL(from: archiveText) == nil)

            Divider().frame(height: 20)

            Toggle("Custom style", isOn: $usesCustomStyle)
                .toggleStyle(.switch)
                .help("Off draws the same tiles with the built-in style")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// The archive URL and the header names are part of the tile cache
    /// identity, which is what keeps caches of different sources apart:
    /// pointing the map elsewhere can never serve the previous source's tiles
    /// from disk.
    private func applyTileSource() {
        guard let archive = Self.archiveURL(from: archiveText) else {
            return
        }
        appliedArchive = archive
        appliedAPIKey = apiKey
    }

    /// The field's text as an archive URL, or nil when it is not one the
    /// loader could reach: the scheme must be http or https, and there must
    /// be a host.
    private static func archiveURL(from text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 48.8566,
        longitudeDegrees: 2.3522,
        zoom: 11.5,
        bearing: 0,
        pitch: 0.2
    )
}
