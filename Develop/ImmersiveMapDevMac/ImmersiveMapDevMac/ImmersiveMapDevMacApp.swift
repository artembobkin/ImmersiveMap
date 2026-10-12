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
    /// The camera's zoom, read off the screen's corner while a gesture is
    /// under way: quicker to glance at than the debug panel's line.
    @State private var zoom: Double?

    var body: some View {
        map
            .overlay(alignment: .topTrailing) {
                if let zoom {
                    Text(String(format: "z %.2f", zoom))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                zoom = Self.start.zoom
                camera.onCameraPositionChanged = { position in
                    zoom = position.zoom
                }
            }
    }

    private var map: some View {
        ImmersiveMapView()
            .tileArchive(devTileArchive)
            .mapStyle(.default.apply { theme in
                theme.features.buildingExtrusion = true
            })
            .extrusion(risesFromTheGround: false)
            .shadows(isEnabled: false)
            .labels(isEnabled: true)
            // The controls are drawn only when a camera controller is attached:
            // they drive it, so without one the modifier does nothing.
            .camera(camera, position: Self.start)
            // Down to the ground: the default stops at 18, two levels past
            // the deepest tile. Here the landmarks are reviewed up close,
            // at about a dozen metres over the pavement at 22.
            .zoomRange(maximum: 22)
            // The relief from zoom 10. A cell of the same ground, about 53 m
            // at Zermatt, at every zoom from 11 on: a ring's terrain is
            // sampled at the same points by a tile and by the coarser tile
            // that stands in for it while it loads, so the ridges do not
            // move when a tile lands. Zoom 10 is at the grid's ceiling.
            .groundFlattening(grid: 32, gridByTileZoom: [10: 256, 11: 256, 12: 128, 13: 64, 14: 32, 15: 16])
            // Mapterhorn's terrain from the plane's first frame, fading to
            // the plane with the zoom, early over flat ground (a city, most
            // likely) and late in the mountains, by the defaults.
            .groundRelief(isEnabled: true, exaggeration: 1)
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
            .modelArchive(devModelArchive, depthBias: 0.00)
            // A tileset under development is rebuilt and re-served under the
            // same coordinates, so a warm disk cache would keep showing the
            // previous build. Every launch here starts from the network.
            .tileSettings(clearDiskCachesOnLaunch: false)
            .labelSettings(language: .english)
            // Camera coordinates and renderer diagnostics, drawn as host-view
            // chrome above the map. A development aid, off by default.
            .debugPanel()
            .ignoresSafeArea()
    }

    /// Strawberry Fields in Central Park at street level, tilted to the
    /// horizon: the camera almost on the ground over a few tiles blown up
    /// to many screens, where the near ground is hardest to draw whole.
    /// The spot has to be inside the coverage the test tileset is built
    /// for. Outside that box the server answers with no tile and the map
    /// is empty by construction, not by a fault in the engine, so a start
    /// position over an uncovered city reads as a bug that is not there.
    /// Zermatt, looking south-west up the valley toward the Matterhorn:
    /// a mountain town for the ground relief, with Swiss lidar terrain.
    private static let start = ImmersiveMapCameraPosition(
        latitudeDegrees: 46.02,
        longitudeDegrees: 7.749,
        zoom: 12.6,
        bearing: 2.36,
        pitch: 1.1
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
