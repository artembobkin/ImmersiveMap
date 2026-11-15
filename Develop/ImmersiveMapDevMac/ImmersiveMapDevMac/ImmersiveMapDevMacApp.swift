// Copyright (c) 2025-2026 Artem Bobkin.
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
    /// New York's open data: every file registered, each drawn by a layer.
    @State private var layers = NewYorkLayers.makeController()
    @State private var camera = ImmersiveMapCameraController()
    /// Every subway station, read once from the file the stations' layer draws.
    @State private var stations = SubwayStation.load()
    /// The stations that carry a name now: the few nearest the camera,
    /// once it is close enough for the stations' dots to show.
    @State private var named: [SubwayStation] = []
    /// The city's landmarks, each a pin.
    @State private var pins = ImmersiveMapPinsController()
    /// Whether pins that overlap push each other apart, switched from the
    /// panel in the corner.
    @State private var pinsSpreadApart = true
    /// The landmark tapped last, shown in the panel.
    @State private var tappedLandmark: String?

    var body: some View {
        ImmersiveMapView()
            .modelArchive(ImmersiveMapTilesService.modelArchiveURL)
            .cameraPosition(.city(.newYork))
            .cameraController(camera)
            .layers(layers)
            // The landmarks are pins: pictures the map draws itself. In
            // Midtown several stand closer than a pin is wide, which shows
            // what `spreadsApart` does: on, they push apart and each stays
            // tied to its place by a beam. Off, they stand on their places
            // and cover each other.
            .pins(pins)
            .pinSettings(size: .px128, sizeScale: 0.85, spreadsApart: pinsSpreadApart)
            .onPinTap { event in
                tappedLandmark = Landmark.all.first { $0.id == event.pin.id }?.name
            }
            // The stations' names are SwiftUI views, one under each dot. A
            // layer draws shapes and no text, and an annotation is a view, so it
            // is for a few of them: only the stations round the camera get
            // one, not all 496. A station can be compared, so when the set
            // changes the map leaves the names that stay as they are.
            .annotations(named, coordinate: \.coordinate, anchor: .top) { station in
                StationName(station.name)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Pins make room for each other", isOn: $pinsSpreadApart)
                    Text(tappedLandmark.map { "Tapped: \($0)" } ?? "Tap a pin")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
            .onAppear {
                pins.set(Landmark.all.compactMap { $0.pin() })
                camera.onCameraPositionChanged = { position in
                    let next = SubwayStation.nearest(to: position, among: stations)
                    // Only a change of the set is a change of the view: the
                    // camera reports every frame of a gesture.
                    if next.map(\.id) != named.map(\.id) {
                        named = next
                    }
                }
            }
    }
}

/// A landmark of New York, shown as a pin: its picture is a SwiftUI view
/// drawn once into an image, which the map then draws itself. An example
/// of the pins API: many pictures at coordinates, taps on them, and pins
/// making room for each other.
private struct Landmark {
    let id: UInt64
    let name: String
    let symbol: String
    let coordinate: GeoCoordinate

    /// The side of a pin's picture, in pixels: the size the pins are set
    /// to in `MapScreen` (`.pinSettings(size: .px128)`).
    static let imageSide: CGFloat = 128

    static let all: [Landmark] = [
        Landmark(1, "Statue of Liberty", "🗽", 40.6892, -74.0445),
        Landmark(2, "Empire State Building", "🏙️", 40.7484, -73.9857),
        Landmark(3, "Central Park", "🌳", 40.7829, -73.9654),
        Landmark(4, "Times Square", "🎭", 40.7580, -73.9855),
        Landmark(5, "Brooklyn Bridge", "🌉", 40.7061, -73.9969),
        Landmark(6, "Grand Central Terminal", "🚉", 40.7527, -73.9772),
        Landmark(7, "The Met", "🏛️", 40.7794, -73.9632),
        Landmark(8, "Yankee Stadium", "⚾️", 40.8296, -73.9262),
        Landmark(9, "Coney Island", "🎡", 40.5749, -73.9859),
        Landmark(10, "JFK Airport", "✈️", 40.6413, -73.7781),
        Landmark(11, "Prospect Park", "🌲", 40.6602, -73.9690),
        Landmark(12, "Unisphere", "🌐", 40.7461, -73.8448),
        Landmark(13, "One World Trade Center", "🏢", 40.7127, -74.0134),
        Landmark(14, "The High Line", "🌿", 40.7480, -74.0048),
        Landmark(15, "Rockefeller Center", "⛸️", 40.7587, -73.9787)
    ]

    private init(_ id: UInt64, _ name: String, _ symbol: String, _ latitude: Double, _ longitude: Double) {
        self.id = id
        self.name = name
        self.symbol = symbol
        coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    /// The landmark's pin, nil when its picture could not be drawn.
    @MainActor
    func pin() -> ImmersiveMapPin? {
        let picture = Text(symbol)
            .font(.system(size: Self.imageSide * 0.6))
            .frame(width: Self.imageSide, height: Self.imageSide)
            .background(Color(white: 0.97))
        let renderer = ImageRenderer(content: picture)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            print("The picture of \(name) could not be drawn")
            return nil
        }
        return ImmersiveMapPin(id: id, coordinate: coordinate, image: image)
    }
}

/// A subway station's name under its dot: small, dark, on a light plate so
/// it reads over the map and over the lines. It takes no touches, so the
/// map under it still pans and zooms.
private struct StationName: View {
    private let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color(white: 0.15))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.white.opacity(0.85), in: Capsule())
            // Below the dot, which is 3 points in radius with a ring.
            .padding(.top, 7)
            .allowsHitTesting(false)
    }
}

/// A subway station of `NYC/subway_stations.geojson`: where it is and what
/// it is called. The app reads the file itself for the names, since a
/// layer keeps a feature's shapes and not its properties.
private struct SubwayStation: Identifiable, Equatable {
    /// The camera zoom the names show from, the zoom the stations' layer
    /// shows its dots from.
    static let minimumZoom: Double = 14
    /// How many stations carry a name at once.
    static let maximumCount = 30

    let id: Int
    let name: String
    let coordinate: GeoCoordinate

    static func load() -> [SubwayStation] {
        struct Document: Decodable {
            struct Feature: Decodable {
                struct Properties: Decodable { let name: String }
                struct Geometry: Decodable { let coordinates: [Double] }
                let properties: Properties
                let geometry: Geometry
            }
            let features: [Feature]
        }
        guard let url = Bundle.main.url(forResource: "subway_stations", withExtension: "geojson", subdirectory: "NYC"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            print("NYC/subway_stations.geojson could not be read for the stations' names")
            return []
        }
        return document.features.enumerated().compactMap { index, feature in
            guard feature.geometry.coordinates.count >= 2 else { return nil }
            return SubwayStation(id: index,
                                 name: feature.properties.name,
                                 coordinate: GeoCoordinate(latitude: feature.geometry.coordinates[1],
                                                           longitude: feature.geometry.coordinates[0]))
        }
    }

    /// The stations to name for a camera: none until it is close enough,
    /// then the nearest to what it looks at, within about the view.
    static func nearest(to position: ImmersiveMapCameraPosition, among stations: [SubwayStation]) -> [SubwayStation] {
        guard position.zoom >= minimumZoom else { return [] }
        // About the width of the view in degrees of longitude at this zoom.
        let reach = 360 / pow(2, position.zoom) * 3
        let shrink = cos(position.latitudeDegrees * .pi / 180)
        func distance(_ station: SubwayStation) -> Double {
            let east = (station.coordinate.longitude - position.longitudeDegrees) * shrink
            let north = station.coordinate.latitude - position.latitudeDegrees
            return (east * east + north * north).squareRoot()
        }
        return stations
            .map { (station: $0, distance: distance($0)) }
            .filter { $0.distance <= reach }
            .sorted { $0.distance < $1.distance }
            .prefix(maximumCount)
            .map(\.station)
            // In the order of the file, so a station's view keeps its place
            // among the others while the set changes round it.
            .sorted { $0.id < $1.id }
    }
}

/// New York City's open data as layers, from the GeoJSON files of the `NYC`
/// folder in the app's bundle: the boroughs, the neighbourhoods, the parks,
/// the bike routes, and the subway's lines and stations. An example of the
/// layers API on real data: each file is registered as a source under its
/// name, and a layer draws it with a style and a zoom range. A file is read
/// when its layer first draws, off the main thread, so the neighbourhoods
/// and the bike routes cost nothing until the camera is near enough to
/// show them. The stations' names are not a layer: they are SwiftUI
/// annotations (`MapScreen`), and the landmarks are pins (`Landmark`). The boroughs and the subway's lines draw from the globe on,
/// which also shows what a layer costs when the whole city is a dot. The
/// subway's lines take their colours from the `stroke`
/// property the files state for each service.
private enum NewYorkLayers {
    static func makeController() -> ImmersiveMapLayersController {
        let controller = ImmersiveMapLayersController()
        controller.onSourceFailed = { name, error in
            print("NYC/\(name).geojson: \(error)")
        }
        let clear = SIMD4<Float>(0, 0, 0, 0)
        let layers = [
            ImmersiveMapLayer(source: "neighborhoods",
                              polygonStyle: ImmersiveMapPolygonStyle(fillColor: SIMD4(0.95, 0.75, 0.20, 0.10),
                                                                     strokeColor: SIMD4(0.55, 0.40, 0.10, 1),
                                                                     strokeWidthPoints: 1),
                              zoomRange: 10.5 ... 30),
            ImmersiveMapLayer(source: "boroughs",
                              polygonStyle: ImmersiveMapPolygonStyle(fillColor: clear,
                                                                     strokeColor: SIMD4(0.15, 0.15, 0.20, 1),
                                                                     strokeWidthPoints: 2.5),
                              zoomRange: 0 ... 10.5),
            ImmersiveMapLayer(source: "parks",
                              // A quiet tint, so the subway's colours lead.
                              polygonStyle: ImmersiveMapPolygonStyle(fillColor: SIMD4(0.45, 0.62, 0.45, 0.18),
                                                                     strokeColor: clear,
                                                                     strokeWidthPoints: 0),
                              zoomRange: 11 ... 30),
            ImmersiveMapLayer(source: "bike_routes",
                              polylineStyle: ImmersiveMapPolylineStyle(color: SIMD4(0.10, 0.55, 0.30, 1), widthPoints: 1.5),
                              zoomRange: 12.5 ... 30),
            ImmersiveMapLayer(source: "subway_lines",
                              polylineStyle: ImmersiveMapPolylineStyle(color: SIMD4(0.5, 0.5, 0.5, 1), widthPoints: 3)),
            ImmersiveMapLayer(source: "subway_stations",
                              pointStyle: ImmersiveMapPointStyle(color: SIMD4(1, 1, 1, 1),
                                                                 radiusPoints: 3,
                                                                 strokeColor: SIMD4(0.10, 0.10, 0.10, 1),
                                                                 strokeWidthPoints: 1.5),
                              zoomRange: 14 ... 30)
        ]
        for layer in layers {
            guard let url = Bundle.main.url(forResource: layer.source, withExtension: "geojson", subdirectory: "NYC") else {
                print("NYC/\(layer.source).geojson is not in the bundle")
                continue
            }
            controller.register(layer.source, geoJSONFile: url)
        }
        controller.set(layers)
        return controller
    }
}
