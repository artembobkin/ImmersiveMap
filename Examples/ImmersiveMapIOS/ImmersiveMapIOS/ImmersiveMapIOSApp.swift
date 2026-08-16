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
/// is read from the local environment (`IMMERSIVEMAP_API_KEY`) so it stays on
/// this machine and never lands in the repository; without it the map renders
/// on the shared anonymous pool.
private let hostedTileTemplate = "https://tiles.immersivemap.dev/{z}/{x}/{y}.mvt"

private func hostedTileHeaders() -> [String: String] {
    guard let key = ProcessInfo.processInfo.environment["IMMERSIVEMAP_API_KEY"],
          key.isEmpty == false else {
        return [:]
    }
    return ["Authorization": "Bearer \(key)"]
}
