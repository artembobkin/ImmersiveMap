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
            .tileArchive(devTileArchive)
            .mapStyle(.default.apply { theme in
                theme.features.buildingExtrusion = true
            })
            .shadows(isEnabled: true)
            .labels(isEnabled: true)
            // The controls are drawn only when a camera controller is attached:
            // they drive it, so without one the modifier does nothing.
            .camera(camera, position: Self.start)
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
    /// currently built for. Outside that box the server answers with no tile ч]and
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

/// The tile source under test: the PMTiles archive the map reads.
///
/// The default is the hosted archive. `IMMERSIVEMAP_DEV_TILE_ARCHIVE` in the
/// scheme environment points the app at another archive URL without touching
/// this file, which is what to reach for when comparing two builds of a
/// tileset.
private let devTileArchive = ProcessInfo.processInfo
    .environment["IMMERSIVEMAP_DEV_TILE_ARCHIVE"]
    .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    ?? URL(string: "https://tiles.immersivemap.dev/20260922.pmtiles")!
