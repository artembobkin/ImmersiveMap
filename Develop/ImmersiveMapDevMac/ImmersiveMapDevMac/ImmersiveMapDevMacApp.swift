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
            // Down to the ground: the default stops at 18, two levels past
            // the deepest tile, because a street tilt past it lays the
            // camera on a few tiles blown up to many screens and their fill
            // fans can show slivers. Here the landmarks are reviewed up
            // close, at about a dozen metres over the pavement at 22.
            .zoomRange(maximum: 22)
            // Close to the ground the haze over the far ground goes, the
            // sky stays: from 19 on only the seam band is left at the line.
            .fog(hazeZoomFade: .fadeOut(from: 18, to: 19))
            // Moscow inside the MKAD ring: the globe turns freely up to zoom
            // 1, the area closes in on the city between zoom 1 and 2, and
            // from zoom 2 on a pull that grows with the distance draws the
            // camera back into it, while a drag is still under way too.
//            .cameraBounds(southWest: GeoCoordinate(latitude: 55.57, longitude: 37.36),
//                          northEast: GeoCoordinate(latitude: 55.92, longitude: 37.86),
//                          pullZoomRange: 1...2,
//                          pullCurve: .easeInOut,
//                          edgeBehavior: .elastic(maximumStretch: 200, pullHalfLife: 0.35, pullProgression: 2))
            // The landmarks of the centre of Moscow, from the model archive:
            // loaded by tile as the camera moves, each in place of the map's
            // own building once it is there.
            // The depth bias is the share of a model's distance from the
            // camera it is drawn nearer by, so it covers the map's own
            // building under it in the tiles that could not leave it out.
            // The value to tune by eye: 0 turns it off.
            .modelArchive(devModelArchive, depthBias: 0.05)
            // A tileset under development is rebuilt and re-served under the
            // same coordinates, so a warm disk cache would keep showing the
            // previous build. Every launch here starts from the network.
            .tileSettings(clearDiskCachesOnLaunch: true)
            .labelSettings(language: .english)
            // Camera coordinates and renderer diagnostics, drawn as host-view
            // chrome above the map. A development aid, off by default.
            .debugPanel()
            .ignoresSafeArea()
    }

    /// Moscow between the Four Seasons and the Bolshoi at zoom 15, tilted so
    /// the landmarks under review read as volumes. The spot is inside the
    /// coverage the test tileset is currently built for. Outside that box the
    /// server answers with no tile and the map is empty by construction, not
    /// by a fault in the engine, so a start position over an uncovered city
    /// reads as a bug that is not there.
    private static let start = ImmersiveMapCameraPosition(
        latitudeDegrees: 55.7587,
        longitudeDegrees: 37.6179,
        zoom: 15,
        bearing: 0,
        pitch: 0.9
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

/// The models under review: the archive of model tiles the map reads,
/// baked in the project the models are made in.
///
/// The default is the hosted archive, one fixed name overwritten by each
/// bake: the engine tells the uploads apart by the archive's ETag.
/// `IMMERSIVEMAP_DEV_MODEL_ARCHIVE` in the scheme environment points the
/// app at another one: a URL, or the path of a file just baked, which is
/// how a re-export is looked at without uploading it.
private let devModelArchive = ProcessInfo.processInfo
    .environment["IMMERSIVEMAP_DEV_MODEL_ARCHIVE"]
    .flatMap { value -> URL? in
        guard value.isEmpty == false else { return nil }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value)
    }
    ?? URL(string: "https://tiles.immersivemap.dev/models.pmtiles")!
