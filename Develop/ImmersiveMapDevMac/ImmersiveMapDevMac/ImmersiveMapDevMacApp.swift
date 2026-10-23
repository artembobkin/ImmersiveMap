// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapDevMacApp: App {
    /// Every control over the map hidden for a clean frame
    /// (`controlsHidden`): Map > Hide Controls, Shift-Command-H.
    @State private var controlsHidden = false
    /// The demo layers shown (`DemoLayers`): Layers menu.
    @State private var demoLayers: Set<DemoLayers.Kind> = Set(DemoLayers.Kind.allCases)

    var body: some Scene {
        WindowGroup("ImmersiveMap Dev") {
            MapScreen(controlsHidden: controlsHidden, demoLayers: demoLayers)
        }
        .defaultSize(width: 1200, height: 860)
        .commands {
            CommandMenu("Map") {
                Toggle("Hide Controls", isOn: $controlsHidden)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandMenu("Layers") {
                ForEach(DemoLayers.Kind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { demoLayers.contains(kind) },
                        set: { isOn in
                            if isOn { demoLayers.insert(kind) } else { demoLayers.remove(kind) }
                        }))
                        .keyboardShortcut(kind.shortcut, modifiers: [.command, .option])
                }
            }
        }
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
    /// Every control over the map hidden.
    let controlsHidden: Bool
    /// The demo layers drawn over the map.
    let demoLayers: Set<DemoLayers.Kind>
    @State private var camera = ImmersiveMapCameraController()

    var body: some View {
        ImmersiveMapView()
            .tileArchive(devTileArchive)
            .mapStyle(.default.apply { theme in
                theme.features.buildingExtrusion = true
            })
            // The buildings from zoom 14, a level before the default's 15,
            // standing up at once.
            .buildingExtrusion(buildingsMinimumZoom: 14, risesFromTheGround: false)
            .labels(isEnabled: true)
            // The controls are drawn only when a camera controller is attached:
            // they drive it, so without one the modifier does nothing.
            .camera(camera, position: Self.start)
            // Down to the ground: the default stops at 18, two levels past
            // the deepest tile. Here the landmarks are reviewed up close,
            // at about a dozen metres over the pavement at 22.
            .zoomRange(maximum: 22)
            // Mapterhorn's terrain, coming in with the zoom from 10 to 11
            // and collapsing into the plane at 13.7, by the defaults.
            .groundRelief(isEnabled: true)
            // Moscow inside the MKAD ring: the globe turns freely up to zoom
            // 1, the area closes in on the city between zoom 1 and 2, and
            // from zoom 2 on a pull that grows with the distance draws the
            // camera back into it, while a drag is still under way too.
            //.cameraBounds(southWest: GeoCoordinate(latitude: 55.57, longitude: 37.36),
            //              northEast: GeoCoordinate(latitude: 55.92, longitude: 37.86),
            //              pullZoomRange: 1...2,
            //              pullCurve: .easeInOut,
            //              edgeBehavior: .elastic(maximumStretch: 200, pullHalfLife: 0.35, pullProgression: 2))
            // The landmarks of the centre of Moscow, from the model archive:
            // loaded by tile as the camera moves, each in place of the map's
            // own building once it is there.
            // The depth bias, the share of a model's distance from the
            // camera it is drawn nearer by so it covers the map's own
            // building under it in the tiles that could not leave it out,
            // is left at its default curve over the zoom and tuned by eye
            // on the debug panel's 3D buildings tab.
            .modelArchive(devModelArchive)
            // A tileset under development is rebuilt and re-served under the
            // same coordinates, so a warm disk cache would keep showing the
            // previous build. Every launch here starts from the network.
            .tileSettings(clearDiskCachesOnLaunch: false)
            .labelSettings(language: .english)
            // The layers of the app's own data: zones, a route, points and
            // a GeoJSON document over Moscow, and a few across the world
            // for the globe. Each is switched in the Layers menu.
            .layers(DemoLayers.layers(demoLayers))
            // Camera coordinates and renderer diagnostics, drawn as host-view
            // chrome above the map, with the zoom badge in the corner: the
            // camera's zoom and the planning zoom, which part over the
            // relief through a drag. A development aid, off by default.
            .debugPanel()
            .controlsHidden(false)
            .ignoresSafeArea()
    }

    /// Strawberry Fields in Central Park at street level, tilted to the
    /// horizon: the camera almost on the ground over a few tiles blown up
    /// to many screens, where the near ground is hardest to draw whole.
    /// The spot has to be inside the coverage the test tileset is built
    /// for. Outside that box the server answers with no tile and the map
    /// is empty by construction, not by a fault in the engine, so a start
    /// position over an uncovered city reads as a bug that is not there.
    /// The centre of Moscow from above, the Kremlin at the middle of the
    /// screen at a street zoom: the city's buildings, roads and labels.
    /// Bearing and pitch in radians.
    private static let start = ImmersiveMapCameraPosition(
        latitudeDegrees: 55.752,
        longitudeDegrees: 37.618,
        zoom: 14.5,
        bearing: 0,
        pitch: 0
    )
}

/// The tile source under test: the PMTiles archive the map reads.
///
/// The default is the local copy of the hosted archive at
/// `LocalTiles/<planet date>.pmtiles` in the repository root (ignored by
/// git), downloaded once so the map reads tiles from disk and the network
/// is out of the picture while the engine is judged. Without that copy the
/// map reads the hosted archive. `IMMERSIVEMAP_DEV_TILE_ARCHIVE` in the
/// scheme environment points the app at another archive without touching
/// this file, a URL or the path of a file, which is what to reach for when
/// comparing two builds of a tileset.
private let devTileArchive: URL = {
    if let value = ProcessInfo.processInfo.environment["IMMERSIVEMAP_DEV_TILE_ARCHIVE"],
       value.isEmpty == false,
       let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value) {
        return url
    }
    let hosted = URL(string: "https://tiles.immersivemap.dev/20260922.pmtiles")!
    let local = repositoryRoot
        .appendingPathComponent("LocalTiles")
        .appendingPathComponent(hosted.lastPathComponent)
    return FileManager.default.fileExists(atPath: local.path) ? local : hosted
}()

/// The root of the repository this app is built from, found from this
/// file's path: the app runs in Debug from the source tree, never shipped.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // ImmersiveMapDevMac
    .deletingLastPathComponent()  // ImmersiveMapDevMac (project)
    .deletingLastPathComponent()  // Develop
    .deletingLastPathComponent()  // repository root

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

/// Layers of made-up data that show what `ImmersiveMapLayer` draws: zones
/// with a hole and a stroke, a route, twenty thousand points, a GeoJSON
/// document styled by its own simplestyle properties, and shapes across
/// the world, one of them over the 180th meridian, to look at on the globe
/// and through the morph. Built once: a layer compares by its data, so the
/// map prepares each for the GPU once however often the view updates.
enum DemoLayers {
    enum Kind: String, CaseIterable, Identifiable {
        case zones, route, points, geoJSON, world

        var id: String { rawValue }

        var title: String {
            switch self {
            case .zones: "Zones (Kremlin, Garden Ring)"
            case .route: "Route (Tverskaya)"
            case .points: "20 000 points"
            case .geoJSON: "GeoJSON (simplestyle)"
            case .world: "World (globe, antimeridian)"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .zones: "1"
            case .route: "2"
            case .points: "3"
            case .geoJSON: "4"
            case .world: "5"
            }
        }
    }

    static func layers(_ kinds: Set<Kind>) -> [ImmersiveMapLayer] {
        // Drawn in this order: the big zones under the points and the route.
        [(Kind.world, world), (.zones, zones), (.geoJSON, geoJSON), (.points, points), (.route, route)]
            .filter { kinds.contains($0.0) }
            .map(\.1)
    }

    private static let moscow = GeoCoordinate(latitude: 55.752, longitude: 37.618)

    /// A circle of `radiusMetres` around `centre`, as a ring.
    private static func circle(around centre: GeoCoordinate, radiusMetres: Double, steps: Int = 96) -> [GeoCoordinate] {
        let metresPerDegree = 111_320.0
        return (0 ..< steps).map { index in
            let angle = Double(index) / Double(steps) * 2 * .pi
            return GeoCoordinate(latitude: centre.latitude + radiusMetres * sin(angle) / metresPerDegree,
                                 longitude: centre.longitude
                                     + radiusMetres * cos(angle) / (metresPerDegree * cos(centre.latitude * .pi / 180)))
        }
    }

    /// The Kremlin as a red zone, and a ring between two circles round the
    /// centre: a zone with a hole.
    private static let zones = ImmersiveMapLayer(
        id: "demo.zones",
        polygons: [
            ImmersiveMapPolygon(exterior: circle(around: moscow, radiusMetres: 2_600),
                                holes: [circle(around: moscow, radiusMetres: 1_600)]),
            ImmersiveMapPolygon(exterior: [GeoCoordinate(latitude: 55.7520, longitude: 37.6114),
                                           GeoCoordinate(latitude: 55.7553, longitude: 37.6178),
                                           GeoCoordinate(latitude: 55.7520, longitude: 37.6230),
                                           GeoCoordinate(latitude: 55.7488, longitude: 37.6185),
                                           GeoCoordinate(latitude: 55.7497, longitude: 37.6122)],
                                style: ImmersiveMapPolygonStyle(fillColor: [0.86, 0.16, 0.16, 0.30],
                                                                strokeColor: [0.86, 0.16, 0.16, 1],
                                                                strokeWidthPoints: 3))
        ],
        polygonStyle: ImmersiveMapPolygonStyle(fillColor: [0.18, 0.47, 0.96, 0.18],
                                               strokeColor: [0.18, 0.47, 0.96, 0.9],
                                               strokeWidthPoints: 2))

    /// Tverskaya from the Kremlin to the Belorussky station, with its stops.
    private static let route: ImmersiveMapLayer = {
        let path = [GeoCoordinate(latitude: 55.7560, longitude: 37.6150),
                    GeoCoordinate(latitude: 55.7600, longitude: 37.6110),
                    GeoCoordinate(latitude: 55.7650, longitude: 37.6050),
                    GeoCoordinate(latitude: 55.7700, longitude: 37.5960),
                    GeoCoordinate(latitude: 55.7745, longitude: 37.5880),
                    GeoCoordinate(latitude: 55.7765, longitude: 37.5815)]
        return ImmersiveMapLayer(
            id: "demo.route",
            polylines: [ImmersiveMapPolyline(coordinates: path)],
            points: [path.first!, path[2], path[4], path.last!].map { ImmersiveMapPoint(coordinate: $0) },
            polylineStyle: ImmersiveMapPolylineStyle(color: [0.55, 0.20, 0.85, 0.95], widthPoints: 6),
            pointStyle: ImmersiveMapPointStyle(color: [1, 1, 1, 1], radiusPoints: 5,
                                               strokeColor: [0.55, 0.20, 0.85, 1], strokeWidthPoints: 3))
    }()

    /// Twenty thousand made-up measurements over Moscow, the colour from
    /// cool to warm with the distance from the centre: what a scientist's
    /// sample looks like on the map. A fixed seed, so every launch draws
    /// the same.
    private static let points: ImmersiveMapLayer = {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        let points = (0 ..< 20_000).map { _ -> ImmersiveMapPoint in
            // Denser towards the centre.
            let distance = pow(random(), 0.7) * 0.25
            let angle = random() * 2 * .pi
            let coordinate = GeoCoordinate(latitude: moscow.latitude + distance * sin(angle) * 0.56,
                                           longitude: moscow.longitude + distance * cos(angle))
            let t = Float(min(distance / 0.25, 1))
            let color = SIMD4<Float>(0.15 + 0.85 * t, 0.75 - 0.35 * t, 1 - 0.85 * t, 0.85)
            return ImmersiveMapPoint(coordinate: coordinate,
                                     style: ImmersiveMapPointStyle(color: color, radiusPoints: 2.5, strokeWidthPoints: 0))
        }
        return ImmersiveMapLayer(id: "demo.points", points: points, zoomRange: 9 ... 30)
    }()

    /// A GeoJSON document whose features carry their own simplestyle
    /// properties: Gorky Park in green, a walk along the river in orange,
    /// two places as large red markers.
    private static let geoJSON: ImmersiveMapLayer = {
        let document = """
        {"type": "FeatureCollection", "features": [
          {"type": "Feature",
           "properties": {"name": "Gorky Park", "fill": "#2ecc71", "fill-opacity": 0.35, "stroke": "#1e8449", "stroke-width": 2},
           "geometry": {"type": "Polygon", "coordinates": [[
             [37.5930, 55.7310], [37.6040, 55.7330], [37.6080, 55.7290],
             [37.5990, 55.7240], [37.5880, 55.7230], [37.5850, 55.7270], [37.5930, 55.7310]]]}},
          {"type": "Feature",
           "properties": {"name": "River walk", "stroke": "#e67e22", "stroke-width": 5},
           "geometry": {"type": "LineString", "coordinates": [
             [37.6090, 55.7440], [37.6040, 55.7395], [37.6010, 55.7350], [37.5960, 55.7320]]}},
          {"type": "Feature",
           "properties": {"name": "Bolshoi Theatre", "marker-color": "#e74c3c", "marker-size": "large"},
           "geometry": {"type": "Point", "coordinates": [37.6186, 55.7601]}},
          {"type": "Feature",
           "properties": {"name": "Red Square", "marker-color": "#e74c3c", "marker-size": "large"},
           "geometry": {"type": "Point", "coordinates": [37.6208, 55.7539]}}
        ]}
        """
        return try! ImmersiveMapLayer(id: "demo.geojson", geoJSON: Data(document.utf8))
    }()

    /// Shapes the size of countries, to see on the globe and through the
    /// morph: a zone over the Bering Strait across the 180th meridian, one
    /// over the Mediterranean, a line from Moscow to New York, and a point
    /// at every capital the line passes.
    private static let world = ImmersiveMapLayer(
        id: "demo.world",
        polygons: [
            ImmersiveMapPolygon(exterior: [GeoCoordinate(latitude: 55, longitude: 160),
                                           GeoCoordinate(latitude: 55, longitude: -160),
                                           GeoCoordinate(latitude: 70, longitude: -160),
                                           GeoCoordinate(latitude: 70, longitude: 160)]),
            ImmersiveMapPolygon(exterior: [GeoCoordinate(latitude: 31, longitude: -5),
                                           GeoCoordinate(latitude: 31, longitude: 36),
                                           GeoCoordinate(latitude: 45, longitude: 36),
                                           GeoCoordinate(latitude: 45, longitude: -5)],
                                style: ImmersiveMapPolygonStyle(fillColor: [0.95, 0.65, 0.10, 0.25],
                                                                strokeColor: [0.95, 0.65, 0.10, 1]))
        ],
        polylines: [ImmersiveMapPolyline(coordinates: [moscow,
                                                       GeoCoordinate(latitude: 52.52, longitude: 13.40),
                                                       GeoCoordinate(latitude: 51.51, longitude: -0.13),
                                                       GeoCoordinate(latitude: 40.71, longitude: -74.01)])],
        points: [moscow,
                 GeoCoordinate(latitude: 52.52, longitude: 13.40),
                 GeoCoordinate(latitude: 51.51, longitude: -0.13),
                 GeoCoordinate(latitude: 40.71, longitude: -74.01)].map { ImmersiveMapPoint(coordinate: $0) },
        polygonStyle: ImmersiveMapPolygonStyle(fillColor: [0.10, 0.70, 0.75, 0.25],
                                               strokeColor: [0.10, 0.70, 0.75, 1]),
        polylineStyle: ImmersiveMapPolylineStyle(color: [0.95, 0.25, 0.45, 1], widthPoints: 3),
        pointStyle: ImmersiveMapPointStyle(color: [0.95, 0.25, 0.45, 1], radiusPoints: 6),
        zoomRange: 0 ... 9)
}
