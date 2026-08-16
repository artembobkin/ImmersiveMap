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
/// is one URL template set with `.tileURLTemplate(_:headers:)`; how the bytes
/// are parsed and drawn is configured separately, with a hand-written
/// `ImmersiveMapVectorTileStyle` wrapped in a `VectorTileMapStyle` plus the
/// label profile naming which MVT properties carry label text.
///
/// The URL below points at the project's own public endpoint so the example
/// runs with no account, but nothing here is specific to it: any endpoint that
/// serves MVT works the same way. Paste yours into the field.
private struct CustomTilesScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var templateText = Self.defaultTemplate
    @State private var apiKey = Self.environmentAPIKey
    @State private var appliedTemplate = Self.defaultTemplate
    @State private var appliedAPIKey = Self.environmentAPIKey
    @State private var usesCustomStyle = true

    /// A public OpenMapTiles-schema endpoint, used so the example starts with
    /// something on screen. Replace it with your own.
    private static let defaultTemplate = "https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt"

    /// Prefills the key field from the local environment or the gitignored
    /// `LocalSecrets.plist`, so the key stays on this machine and never lands
    /// in the repository. Empty means anonymous.
    private static let environmentAPIKey = localAPIKey() ?? ""

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
    /// The tile source is always the applied template; only the style is
    /// toggled, so the comparison is like for like: the same bytes drawn by
    /// the hand-written style versus by the built-in one.
    private var mapView: ImmersiveMapView {
        // Credentials travel as request headers (or inside the template's
        // query string). Empty means anonymous.
        let headers = appliedAPIKey.isEmpty ? [:] : ["Authorization": "Bearer \(appliedAPIKey)"]
        let base = ImmersiveMapView()
            .camera(camera, position: Self.overview)
            .tileURLTemplate(appliedTemplate, headers: headers)
            // Required by the data licence, and it has to name what is
            // actually being served. This example defaults to the hosted
            // endpoint, an OpenStreetMap planet in the OpenMapTiles schema, so
            // the badge credits both. Point the URL field at your own source
            // and this string becomes yours to get right, see ATTRIBUTION.md.
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(
                attributionOverride: ImmersiveMapAttribution(
                    title: "© OpenStreetMap © OpenMapTiles",
                    copyright: "",
                    linkURL: URL(string: "https://www.openstreetmap.org/copyright"))))
        guard usesCustomStyle else {
            return base
        }
        return base.mapStyle(VectorTileMapStyle(
            style: DemoTileStyle(),
            // Which MVT properties carry the label text, its rank and its kind.
            labelProfile: ImmersiveMapVectorTileLabelProfile(
                textKeys: ["name:en", "name"],
                rankKeys: ["rank"],
                kindKeys: ["class"],
                pointLabelLayers: ["place"])))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("https://host/tiles/{z}/{x}/{y}.mvt", text: $templateText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 330)
            SecureField("api key (optional)", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button("Apply") {
                applyTileSource()
            }
            .disabled(templateText.isEmpty)

            Divider().frame(height: 20)

            Toggle("Custom style", isOn: $usesCustomStyle)
                .toggleStyle(.switch)
                .help("Off draws the same tiles with the built-in style")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// The template and the header names are part of the tile cache identity,
    /// which is what keeps caches of different sources apart: pointing the map
    /// elsewhere can never serve the previous source's tiles from disk.
    private func applyTileSource() {
        appliedTemplate = templateText
        appliedAPIKey = apiKey
    }

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 48.8566,
        longitudeDegrees: 2.3522,
        zoom: 11.5,
        bearing: 0,
        pitch: 0.2
    )
}

/// The environment wins (the scheme carries an empty placeholder for it);
/// otherwise the key comes from the gitignored `LocalSecrets.plist` at the
/// repository root, found from this source file's path, which exists wherever
/// the app can also read it: on the Mac and in the simulator. A physical
/// device sees neither and uses the scheme variable.
private func localAPIKey() -> String? {
    if let key = ProcessInfo.processInfo.environment["IMMERSIVEMAP_API_KEY"],
       key.isEmpty == false {
        return key
    }
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            let secrets = directory.appendingPathComponent("LocalSecrets.plist")
            return NSDictionary(contentsOf: secrets)?["IMMERSIVEMAP_API_KEY"] as? String
        }
        directory = directory.deletingLastPathComponent()
    }
    return nil
}
