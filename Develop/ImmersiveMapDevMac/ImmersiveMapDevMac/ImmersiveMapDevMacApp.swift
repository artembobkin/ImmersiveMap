// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapDevMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Dev") {
            MapScreen()
        }
        .defaultSize(width: 1200, height: 860)
    }
}

/// The scratch map: the plain view with the camera controls and the debug HUD,
/// pointed at whatever tile source is being worked on this week rather than at
/// the hosted one.
///
/// `Examples/macOS/ImmersiveMapMac` is the same screen for a reader: it shows
/// the engine on the shipping tile service, with the defaults untouched, and it
/// stays that way. This one is free to move: change the source, the start
/// position, the settings, and leave the state of the current experiment
/// committed, because that is the point of the folder.
private struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()

    var body: some View {
        ImmersiveMapView()
            .tileURLTemplate(devTileTemplate, headers: devTileHeaders())
            // The controls are drawn only when a camera controller is attached:
            // they drive it, so without one the modifier does nothing.
            .camera(camera, position: Self.start)
            .enableCameraUIControls()
            // A tileset under development is rebuilt and re-served under the
            // same coordinates, so a warm disk cache would keep showing the
            // previous build. Every launch here starts from the network.
            .tileSettings(clearDiskCachesOnLaunch: true)
            // Camera coordinates and renderer diagnostics, drawn as host-view
            // chrome above the map. A development aid, off by default.
            .debugPanel()
            .ignoresSafeArea()
    }

    /// Moscow at street level, which is inside the coverage the test tileset is
    /// currently built for. Outside that box the server answers with no tile and
    /// the map is empty by construction, not by a fault in the engine, so a
    /// start position over an uncovered city reads as a bug that is not there.
    private static let start = ImmersiveMapCameraPosition(
        latitudeDegrees: 55.7558,
        longitudeDegrees: 37.6173,
        zoom: 16,
        bearing: 0,
        pitch: 0
    )
}

/// The tile source under test, written as the one-line URL template.
///
/// The default is the test endpoint that serves tiles cut by our own generator
/// straight from OSM into the ImmersiveMap schema: only the layers and fields
/// the style actually reads, plus the road lane counts that OpenMapTiles does
/// not carry. `IMMERSIVEMAP_DEV_TILE_TEMPLATE` in the scheme environment points
/// the app somewhere else without touching this file, which is what to reach for
/// when comparing two builds of a tileset.
private let devTileTemplate = ProcessInfo.processInfo
    .environment["IMMERSIVEMAP_DEV_TILE_TEMPLATE"]
    .flatMap { $0.isEmpty ? nil : $0 }
    ?? "https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt"

/// The test endpoint takes the same key as the hosted service, so there is one
/// entry to keep: `IMMERSIVEMAP_API_KEY`.
private func devTileHeaders() -> [String: String] {
    guard let key = localAPIKey(), key.isEmpty == false else {
        return [:]
    }
    return ["Authorization": "Bearer \(key)"]
}

/// The environment wins (the scheme carries an empty placeholder for it);
/// otherwise the key comes from the gitignored `LocalSecrets.plist` at the
/// repository root, found from this source file's path, which exists wherever
/// the app can also read it: on the Mac and in the simulator. A physical
/// device sees neither and uses the scheme variable.
private func localAPIKey(named name: String = "IMMERSIVEMAP_API_KEY") -> String? {
    if let key = ProcessInfo.processInfo.environment[name],
       key.isEmpty == false {
        return key
    }
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            let secrets = directory.appendingPathComponent("LocalSecrets.plist")
            return NSDictionary(contentsOf: secrets)?[name] as? String
        }
        directory = directory.deletingLastPathComponent()
    }
    return nil
}
