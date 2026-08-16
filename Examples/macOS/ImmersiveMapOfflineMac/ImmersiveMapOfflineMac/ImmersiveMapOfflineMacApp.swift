// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapOfflineMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Offline Regions") {
            OfflineScreen()
        }
        .defaultSize(width: 1250, height: 820)
    }
}

/// Offline regions end to end: download a city with
/// `ImmersiveMapOfflineController`, watch the progress, then flip the map to
/// "Offline only" and pan around the downloaded area; tiles keep rendering
/// with the network never touched. Outside the region the map stays empty,
/// which is the honest picture of what offline mode has.
///
/// The controller and the map never meet: both derive the same on-disk store
/// location from the tile source in the settings, so serving needs no wiring.
/// In this app both use the default hosted source.
private struct OfflineScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var offlineController = ImmersiveMapOfflineController()
    @State private var regionStatuses: [ImmersiveMapOfflineRegionStatus] = []
    @State private var offlineMode = ImmersiveMapSettings.TileSettings.OfflineSettings.Mode.automatic
    @State private var lastErrorText: String?

    var body: some View {
        HSplitView {
            OfflineRegionsPanel(offlineController: offlineController,
                                camera: camera,
                                regionStatuses: $regionStatuses,
                                offlineMode: $offlineMode,
                                lastErrorText: $lastErrorText)
                .frame(minWidth: 340, maxWidth: 400)

            ImmersiveMapView()
                .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
                .camera(camera, position: OfflineRegionsPanel.presets.first!.cameraPosition)
                .offlineTileMode(offlineMode)
                .enableCameraUIControls()
                .ignoresSafeArea()
                .frame(minWidth: 600)
        }
        .onAppear {
            offlineController.onRegionsChanged = {
                regionStatuses = offlineController.regions
            }
            regionStatuses = offlineController.regions
        }
    }
}

/// The hosted tile endpoint, written as the one-line URL template. The API key
/// is read from the local environment (`IMMERSIVEMAP_API_KEY`) so it stays on
/// this machine and never lands in the repository; without it the map renders
/// on the shared anonymous pool.
private let hostedTileTemplate = "https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt"

private func hostedTileHeaders() -> [String: String] {
    guard let key = ProcessInfo.processInfo.environment["IMMERSIVEMAP_API_KEY"],
          key.isEmpty == false else {
        return [:]
    }
    return ["Authorization": "Bearer \(key)"]
}
