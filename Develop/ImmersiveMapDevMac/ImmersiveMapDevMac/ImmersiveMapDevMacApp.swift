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
            .landmarks(DevLandmarks.landmarks)
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
/// element its geometry was modelled from, from zoom 15 on. Below it the
/// map's own building stands. A missing file is skipped rather than
/// reported.
///
/// The Kremlin is the tiled set (`Kremlin_Tiled/manifest.json`): one
/// landmark per tower, wall section, building and monument, each at its
/// own origin, read from the manifest at launch. The assembled
/// `Kremlin_Ensemble` is for review in Blender only and is not loaded with
/// the parts.
private enum DevLandmarks {
    static let landmarks: [ImmersiveMapLandmark] = [
        landmark(id: "four-seasons",
                 file: "FourSeasons_Moscow_512/four_seasons_moscow_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.75734215, longitude: 37.6172596),
                 replacedBuilding: .relation(225030)),
        landmark(id: "bolshoi",
                 file: "Bolshoi_Theatre_512/bolshoi_theatre_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.76013, longitude: 37.61861),
                 replacedBuilding: .relation(3334755)),
        landmark(id: "gum",
                 file: "GUM_512/gum_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.7546967704, longitude: 37.6214240342),
                 replacedBuilding: .relation(3330565)),
        landmark(id: "historical-museum",
                 file: "Historical_Museum_512/historical_museum_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.75538, longitude: 37.61777),
                 replacedBuilding: .relation(5963922)),
        landmark(id: "tsum",
                 file: "TSUM_512/tsum_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.76065, longitude: 37.6198),
                 replacedBuilding: .relation(2669485)),
        // Okhotny Ryad is mostly underground: the model is built from the
        // floor of its open pit, with the square on top of it. Sunk by the
        // height of the square, so the square lies on the map surface, and
        // cut into the ground, so the pit is seen from above and the walls
        // below the square stay hidden from the streets around it.
        landmark(id: "okhotny-ryad",
                 file: "Okhotny_Ryad_512/okhotny_ryad_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.7553, longitude: 37.6143),
                 replacedBuilding: .relation(6233742),
                 altitudeMeters: -6.5,
                 cutsIntoGround: true),
        landmark(id: "metropol",
                 file: "Metropol_512/metropol_512.usdz",
                 coordinate: GeoCoordinate(latitude: 55.75848895051534, longitude: 37.62163281921604),
                 replacedBuilding: .relation(85761)),
    ].compactMap { $0 } + kremlinParts()

    private static let minimumZoom = 15

    private static func landmark(id: String,
                                 file: String,
                                 coordinate: GeoCoordinate,
                                 replacedBuilding: ImmersiveMapOSMElement?,
                                 altitudeMeters: Double = 0,
                                 cutsIntoGround: Bool = false) -> ImmersiveMapLandmark? {
        let url = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return ImmersiveMapLandmark(id: id,
                                    model: .init(url: url),
                                    coordinate: coordinate,
                                    replacedBuilding: replacedBuilding,
                                    altitudeMeters: altitudeMeters,
                                    cutsIntoGround: cutsIntoGround,
                                    minimumZoom: minimumZoom)
    }

    // MARK: - The Kremlin

    /// The part of `Kremlin_Tiled/manifest.json` the app reads.
    private struct KremlinManifest: Decodable {
        struct Part: Decodable {
            struct Origin: Decodable {
                let lat: Double
                let lon: Double
            }
            struct Files: Decodable {
                let usdz: String
            }
            let id: String
            let origin: Origin
            let files: Files
        }
        let parts: [Part]
    }

    private static let kremlinFolder = "Kremlin_Tiled"

    private static func kremlinParts() -> [ImmersiveMapLandmark] {
        let url = directory.appendingPathComponent(kremlinFolder).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(KremlinManifest.self, from: data) else {
            return []
        }
        return manifest.parts.compactMap { part in
            landmark(id: "kremlin-\(part.id)",
                     file: "\(kremlinFolder)/\(part.files.usdz)",
                     coordinate: GeoCoordinate(latitude: part.origin.lat, longitude: part.origin.lon),
                     replacedBuilding: kremlinElement(partID: part.id))
        }
    }

    /// The OSM element a Kremlin part was modelled from. The manifest names
    /// a part by the element's number and not its type: the towers, the
    /// wall sections, the churches and most buildings are relations, and
    /// the ways are listed. A part named in words takes the element of its
    /// source inventory. The Troitsky bridge has none and replaces nothing,
    /// and a monument that is a node replaces nothing either, since no
    /// building is a node.
    private static func kremlinElement(partID: String) -> ImmersiveMapOSMElement? {
        if let named = kremlinNamedParts[partID] {
            return named
        }
        guard let number = partID.split(separator: "_").last.flatMap({ UInt64($0) }) else {
            return nil
        }
        return kremlinWays.contains(number) ? .way(number) : .relation(number)
    }

    private static let kremlinWays: Set<UInt64> = [
        247_986_327, 534_095_307, 534_095_308, 534_095_310, 534_095_312, 534_095_313, 534_437_577,
        1_214_065_860, 1_219_452_673, 1_219_452_674,
    ]

    private static let kremlinNamedParts: [String: ImmersiveMapOSMElement?] = [
        "building_arsenal": .relation(51497),
        "building_senate_palace": .relation(1_359_233),
        "building_grand_kremlin_palace": .relation(225_033),
        "building_state_kremlin_palace": .relation(3_031_379),
        "building_armoury": .relation(1_359_335),
        "building_poteshny_palace": .relation(1_359_337),
        "building_faceted_palace": .relation(7_679_578),
        "monument_cross": .way(535_143_215),
        "monument_firebird": .way(1_219_480_806),
        "monument_cannon": nil,
        "monument_bell": nil,
        "monument_cadets": nil,
        "troitsky_bridge": nil,
    ]

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
