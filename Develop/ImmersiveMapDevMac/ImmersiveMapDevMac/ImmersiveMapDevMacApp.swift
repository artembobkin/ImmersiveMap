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
    }
}

private struct MapScreen: View {
    /// The opacity tried for the names over the map, letters and halo
    /// alike. The built-in style lays them at 0.9.
    private static let labelOpacity: Float = 0.8

    var body: some View {
        ImmersiveMapView()
            .debugPanel(.hud)
            .mapStyle(ProtomapsBasemapMapStyle.default.apply { theme in
                let kinds: [WritableKeyPath<ProtomapsBasemapTheme.LabelStyles, ProtomapsBasemapTheme.LabelAppearance>] =
                    [\.city, \.town, \.district, \.poi, \.road, \.water]
                for kind in kinds {
                    theme.labels[keyPath: kind].opacity = Self.labelOpacity
                }
            })
    }
}
