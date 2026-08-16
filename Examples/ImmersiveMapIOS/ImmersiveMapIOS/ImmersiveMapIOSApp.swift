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
            .camera(camera)
            .tileURLTemplate("https://tucik.moscow/tiles/{z}/{x}/{y}.mvt")
            // One-thumb pitch and zoom drag zones in the bottom corners. Touch
            // platforms only, so this is the one example that can show them.
            .cameraControlZones()
            .ignoresSafeArea()
    }
}
