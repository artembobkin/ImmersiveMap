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
            .landmarks(DevLandmarks.landmarks)
            // A tileset under development is rebuilt and re-served under the
            // same coordinates, so a warm disk cache would keep showing the
            // previous build. Every launch here starts from the network.
            .tileSettings(clearDiskCachesOnLaunch: true)
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

/// The landmarks under review: USDZ exports read straight from the modeling
/// folder, so a re-export shows up on the next launch without copying
/// anything into the app. `IMMERSIVEMAP_DEV_MODELS_DIR` in the scheme
/// environment points at another folder. The exports are Y-up meters with -Z
/// north and their origin at the anchor coordinate, so they need no heading
/// or scale. Each replaces the map's building by its OSM outline, the
/// relation its geometry was modelled from, from zoom 15 on. Below it the
/// map's own building stands. A missing file is skipped rather than
/// reported.
private enum DevLandmarks {
    static let landmarks: [ImmersiveMapLandmark] = [
        landmark(id: "four-seasons",
                 file: "FourSeasons_Moscow_512/four_seasons_moscow_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.75734215, longitude: 37.6172596),
                 replacedBuilding: .relation(225030),
                 minimumZoom: 15),
        landmark(id: "bolshoi",
                 file: "Bolshoi_Theatre_512/bolshoi_theatre_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.76013, longitude: 37.61861),
                 replacedBuilding: .relation(3334755),
                 minimumZoom: 15),
    ].compactMap { $0 }

    private static func landmark(id: String,
                                 file: String,
                                 coordinate: GeoCoordinate,
                                 replacedBuilding: ImmersiveMapOSMElement,
                                 minimumZoom: Int) -> ImmersiveMapLandmark? {
        let url = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return ImmersiveMapLandmark(id: id,
                                    model: .init(url: url),
                                    coordinate: coordinate,
                                    replacedBuilding: replacedBuilding,
                                    minimumZoom: minimumZoom)
    }

    private static let directory: URL = ProcessInfo.processInfo
        .environment["IMMERSIVEMAP_DEV_MODELS_DIR"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Modeling", isDirectory: true)
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
