// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap
import ImmersiveMapDebug

@main
struct ImmersiveMapDevMacApp: App {
    /// Every control over the map hidden for a clean frame
    /// (`controlsHidden`): Map > Hide Controls, Shift-Command-H.
    @State private var controlsHidden = false
    /// The demo layers shown (`DemoLayers`): Layers menu.
    @State private var demoLayers: Set<DemoLayers.Kind> = Set(DemoLayers.Kind.allCases)
    /// The SwiftUI markers shown (`DemoMarkers`): Map > SwiftUI Markers,
    /// Shift-Command-M.
    @State private var showsMarkers = true

    var body: some Scene {
        WindowGroup("ImmersiveMap Dev") {
            MapScreen(controlsHidden: controlsHidden, demoLayers: demoLayers, showsMarkers: showsMarkers)
        }
        .defaultSize(width: 1200, height: 860)
        .commands {
            CommandMenu("Map") {
                Toggle("Hide Controls", isOn: $controlsHidden)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Toggle("SwiftUI Markers", isOn: $showsMarkers)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
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
/// It is free to move: change the source, the start position, the settings,
/// and leave the state of the current experiment committed, because that is
/// the point of the folder.
private struct MapScreen: View {
    /// Every control over the map hidden.
    let controlsHidden: Bool
    /// The demo layers drawn over the map.
    let demoLayers: Set<DemoLayers.Kind>
    /// The SwiftUI markers drawn over the map.
    let showsMarkers: Bool
    @State private var camera = ImmersiveMapCameraController()
    /// The place whose marker is opened by a click.
    @State private var selectedPlace: DemoPlace.ID?
    /// Seconds since the courier set off (`DemoMarkers.markers(rideTime:)`).
    @State private var rideTime = 0.0

    var body: some View {
        ImmersiveMapView()
            .tileArchive(devTileArchive)
            .mapStyle(.default.apply { theme in
                theme.features.buildingExtrusion = true
                // The map's own POI icons stand down while the SwiftUI
                // markers are on, so the markers read as the app's views and
                // not as more of the map's icons. The street names stay.
                if showsMarkers {
                    theme.labelVisibility.poiMinimumZoom = 99
                }
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
            // Plain SwiftUI views pinned to coordinates: places around the
            // Kremlin that open on a click, and a courier riding up
            // Tverskaya, moved by setting its coordinate.
            .markers(showsMarkers ? DemoMarkers.markers(rideTime: rideTime) : [],
                     coordinate: \.coordinate,
                     anchor: .bottom) { place in
                if place.id == DemoMarkers.courierID {
                    CourierMarker(eta: place.detail)
                } else {
                    PlaceMarker(place: place, isSelected: selectedPlace == place.id) {
                        withAnimation(.snappy) {
                            selectedPlace = selectedPlace == place.id ? nil : place.id
                        }
                    }
                }
            }
            // The layers of the app's own data: zones, a route, points and
            // a GeoJSON document over Moscow, and a few across the world
            // for the globe. Each is switched in the Layers menu.
            //.layers(DemoLayers.layers(demoLayers))
            // Camera coordinates and renderer diagnostics, drawn as host-view
            // chrome above the map, with the zoom badge in the corner: the
            // camera's zoom and the planning zoom, which part over the
            // relief through a drag. A development aid, off by default.
            .debugPanel(.hud)
            .controlsHidden(true)
            .ignoresSafeArea()
            .task(id: showsMarkers) {
                guard showsMarkers else { return }
                let start = ContinuousClock.now
                while Task.isCancelled == false {
                    let elapsed = (ContinuousClock.now - start).components
                    rideTime = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
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

/// A place on the map shown by a SwiftUI marker (`DemoMarkers`).
struct DemoPlace: Identifiable {
    let id: String
    let name: String
    /// A line under the name. For the courier, the minutes to the end of
    /// the street it rides to.
    let detail: String
    let symbol: String
    let color: Color
    let coordinate: GeoCoordinate
}

/// SwiftUI views over the centre of Moscow, to show what `markers(_:)`
/// draws: place cards that open on a click with a button inside, and a
/// courier that rides along Tverskaya and back with its minutes counting
/// down, moved by nothing but its coordinate.
enum DemoMarkers {
    static let courierID = "courier"

    static let places = [
        DemoPlace(id: "bolshoi", name: "Bolshoi Theatre", detail: "Swan Lake tonight, 19:00",
                  symbol: "theatermasks.fill", color: .purple,
                  coordinate: GeoCoordinate(latitude: 55.7601, longitude: 37.6186)),
        DemoPlace(id: "gum", name: "GUM", detail: "Ice cream on the first floor",
                  symbol: "bag.fill", color: .pink,
                  coordinate: GeoCoordinate(latitude: 55.7547, longitude: 37.6215)),
        DemoPlace(id: "st-basil", name: "Saint Basil's Cathedral", detail: "Open until 19:00",
                  symbol: "building.columns.fill", color: .red,
                  coordinate: GeoCoordinate(latitude: 55.7525, longitude: 37.6231)),
        DemoPlace(id: "zaryadye", name: "Zaryadye Park", detail: "The floating bridge over the river",
                  symbol: "leaf.fill", color: .green,
                  coordinate: GeoCoordinate(latitude: 55.7512, longitude: 37.6285)),
        DemoPlace(id: "pushkin", name: "Pushkin Square", detail: "Meet at the monument",
                  symbol: "person.2.fill", color: .blue,
                  coordinate: GeoCoordinate(latitude: 55.7655, longitude: 37.6060)),
    ]

    /// Tverskaya from the Kremlin to the Belorussky station.
    private static let tverskaya = [
        GeoCoordinate(latitude: 55.7560, longitude: 37.6150),
        GeoCoordinate(latitude: 55.7600, longitude: 37.6110),
        GeoCoordinate(latitude: 55.7650, longitude: 37.6050),
        GeoCoordinate(latitude: 55.7700, longitude: 37.5960),
        GeoCoordinate(latitude: 55.7745, longitude: 37.5880),
        GeoCoordinate(latitude: 55.7765, longitude: 37.5815),
    ]

    /// Seconds the courier takes from one end of the street to the other.
    private static let rideSeconds = 24.0
    /// The minutes the courier's label shows for the whole street.
    private static let rideMinutes = 12.0

    /// The places and the courier `rideTime` seconds after it set off: up
    /// the street and back, its label counting the minutes to the end it
    /// rides to.
    static func markers(rideTime: Double) -> [DemoPlace] {
        let phase = (rideTime / rideSeconds).truncatingRemainder(dividingBy: 2)
        let progress = phase <= 1 ? phase : 2 - phase
        let remaining = phase <= 1 ? 1 - phase : phase - 1
        let minutes = max(Int((remaining * rideMinutes).rounded(.up)), 1)
        return places + [DemoPlace(id: courierID, name: "Courier", detail: "\(minutes) min",
                                   symbol: "bicycle", color: .orange,
                                   coordinate: courierCoordinate(at: progress))]
    }

    /// The point `progress` of the way along Tverskaya, by length.
    private static func courierCoordinate(at progress: Double) -> GeoCoordinate {
        let lengths = zip(tverskaya, tverskaya.dropFirst()).map { a, b in
            hypot(b.latitude - a.latitude, (b.longitude - a.longitude) * cos(a.latitude * .pi / 180))
        }
        var remaining = min(max(progress, 0), 1) * lengths.reduce(0, +)
        for (index, length) in lengths.enumerated() {
            if remaining <= length || index == lengths.count - 1 {
                let t = length > 0 ? min(remaining / length, 1) : 0
                let a = tverskaya[index], b = tverskaya[index + 1]
                return GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                     longitude: a.longitude + (b.longitude - a.longitude) * t)
            }
            remaining -= length
        }
        return tverskaya[tverskaya.count - 1]
    }
}

/// A place's card: its icon and name on a white card whose tail points at
/// the place. A click opens a line of detail and a Directions button, which
/// keeps its own state while the card is open.
private struct PlaceMarker: View {
    let place: DemoPlace
    let isSelected: Bool
    let action: () -> Void
    @State private var isOnTheWay = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: place.symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(place.color.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.top, isSelected ? 0 : 9)
                    if isSelected {
                        Text(place.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button {
                            withAnimation(.snappy) { isOnTheWay.toggle() }
                        } label: {
                            Label(isOnTheWay ? "On the way" : "Directions",
                                  systemImage: isOnTheWay ? "checkmark" : "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(place.color)
                        .padding(.top, 4)
                    }
                }
                .fixedSize()
            }
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            MarkerTail()
                .fill(.white)
                .frame(width: 18, height: 10)
        }
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// The courier: a pulsing icon under a label with the minutes it has left,
/// both read from the marker's data on every update.
private struct CourierMarker: View {
    let eta: String
    @State private var pulses = false

    var body: some View {
        VStack(spacing: 6) {
            Text(eta)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: eta)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.8), in: Capsule())
            Image(systemName: "bicycle")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.orange.gradient, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .background(
                    Circle()
                        .fill(Color.orange.opacity(0.4))
                        .scaleEffect(pulses ? 2.2 : 1)
                        .opacity(pulses ? 0 : 1)
                )
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulses = true
            }
        }
    }
}

/// The triangle under a card, pointing down at the place.
private struct MarkerTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
