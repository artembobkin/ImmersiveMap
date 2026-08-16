// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapIOSApp: App {
    var body: some Scene {
        WindowGroup {
            MapScreen()
        }
    }
}

/// The only iOS host in the repository, kept deliberately minimal: it exists to
/// run the public SwiftUI API on the UIKit view and on real touch input, and it
/// is the app the binary-size numbers in the README are measured frowm. The
/// feature demos are the macOS examples; the API they use is identical here.
private struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()

    var body: some View {
        ImmersiveMapView()
            .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
            .camera(camera)
            // One-thumb pitch and zoom drag zones in the bottom corners. Touch
            // platforms only, so this is the one example that can show them.
            .cameraControlZones()
            .ignoresSafeArea()
    }
}

/// The hosted tile endpoint, written as the one-line URL template. The API key
/// comes from `IMMERSIVEMAP_API_KEY` in the environment or from the gitignored
/// `LocalSecrets.plist` at the repository root, so a real key never has to be
/// typed into a committed scheme; without a key the map renders on the shared
/// anonymous pool.
private let hostedTileTemplate = "https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt"

private func hostedTileHeaders() -> [String: String] {
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
