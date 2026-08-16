// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap") {
            MapScreen()
        }
        .defaultSize(width: 1200, height: 860)
    }
}

/// The plain map on macOS: the built-in tile provider, the on-screen camera
/// controls and the debug HUD, and nothing else. The other Mac examples each
/// document one API and bury the map under a panel of switches; this one is the
/// map itself, which is what to open to fly around, to read the HUD while
/// something is being changed in the engine, or to see what the defaults look
/// like before any setting is touched.
private struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()

    var body: some View {
        ImmersiveMapView()
            .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
            // The controls are drawn only when a camera controller is attached:
            // they drive it, so without one the modifier does nothing.
            .camera(camera, position: Self.start)
            .enableCameraUIControls()
            // Camera coordinates and renderer diagnostics, drawn as host-view
            // chrome above the map. A development aid, off by default.
            .debugPanel()
            .ignoresSafeArea()
    }

    /// Barcelona at street level with the camera tilted, so buildings, their
    /// shadows and the label layout are all on screen at launch.
    private static let start = ImmersiveMapCameraPosition(
        latitudeDegrees: 41.3874,
        longitudeDegrees: 2.1686,
        zoom: 16,
        bearing: 0,
        pitch: 0.9
    )
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
