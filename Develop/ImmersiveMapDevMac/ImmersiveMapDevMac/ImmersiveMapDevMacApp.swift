// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap
import ImmersiveMapDebug

@main
struct ImmersiveMapDevMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Dev") {
            MapScreen()
        }
        // The size a new window opens at. macOS restores the size of a
        // window the user has resized, so this applies only to a window
        // without a saved size.
        .defaultSize(width: 1440, height: 900)
    }
}

private struct MapScreen: View {
    /// The layers of `LayersTest.geojson`, every kind of shape the layers
    /// draw, read once.
    private let layers: [ImmersiveMapLayer] = {
        guard let url = Bundle.main.url(forResource: "LayersTest", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let layer = try? ImmersiveMapLayer(id: "test", geoJSON: data) else { return [] }
        return [layer]
    }()

    var body: some View {
        ImmersiveMapView()
            .modelArchive(ImmersiveMapTilesService.modelArchiveURL)
            .layers(layers)
    }
}
