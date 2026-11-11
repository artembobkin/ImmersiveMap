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
        // The size a new window opens at. macOS restores the size of a
        // window the user has resized, so this applies only to a window
        // without a saved size.
        .defaultSize(width: 1440, height: 900)
    }
}

private struct MapScreen: View {
    /// New York's open data, empty until it has been read.
    @State private var layers = ImmersiveMapLayersController()

    var body: some View {
        ImmersiveMapView()
            .modelArchive(ImmersiveMapTilesService.modelArchiveURL)
            .cameraPosition(.city(.newYork))
            .layers(layers)
            .task {
                // The files are read off the main thread: a layer reads its
                // GeoJSON where it is made, and these hold 18 MB. The
                // controller takes them from that thread.
                let layers = layers
                await Task.detached(priority: .userInitiated) { layers.set(NewYorkLayers.load()) }.value
            }
    }
}

/// New York City's open data as layers, from the GeoJSON files of the `NYC`
/// folder in the app's bundle: the boroughs, the neighbourhoods, the parks,
/// the bike routes, and the subway's lines and stations. An example of the
/// layers API on real data, with a style and a zoom range for each layer.
/// The subway's lines take their colours from the `stroke` property the
/// files state for each service.
private enum NewYorkLayers {
    static func load() -> [ImmersiveMapLayer] {
        let clear = SIMD4<Float>(0, 0, 0, 0)
        return [
            layer("neighborhoods",
                  polygonStyle: ImmersiveMapPolygonStyle(fillColor: SIMD4(0.95, 0.75, 0.20, 0.10),
                                                         strokeColor: SIMD4(0.55, 0.40, 0.10, 0.8),
                                                         strokeWidthPoints: 1),
                  zoomRange: 10.5 ... 30),
            layer("boroughs",
                  polygonStyle: ImmersiveMapPolygonStyle(fillColor: clear,
                                                         strokeColor: SIMD4(0.15, 0.15, 0.20, 1),
                                                         strokeWidthPoints: 2.5),
                  zoomRange: 0 ... 10.5),
            layer("parks",
                  polygonStyle: ImmersiveMapPolygonStyle(fillColor: SIMD4(0.20, 0.65, 0.30, 0.45),
                                                         strokeColor: clear,
                                                         strokeWidthPoints: 0),
                  zoomRange: 11 ... 30),
            layer("bike_routes",
                  polylineStyle: ImmersiveMapPolylineStyle(color: SIMD4(0.10, 0.55, 0.30, 0.9), widthPoints: 1.5),
                  zoomRange: 12.5 ... 30),
            layer("subway_lines",
                  polylineStyle: ImmersiveMapPolylineStyle(color: SIMD4(0.5, 0.5, 0.5, 1), widthPoints: 3)),
            layer("subway_stations",
                  pointStyle: ImmersiveMapPointStyle(color: SIMD4(1, 1, 1, 1),
                                                     radiusPoints: 3,
                                                     strokeColor: SIMD4(0.10, 0.10, 0.10, 1),
                                                     strokeWidthPoints: 1.5),
                  zoomRange: 12 ... 30)
        ].compactMap { $0 }
    }

    private static func layer(_ name: String,
                              polygonStyle: ImmersiveMapPolygonStyle = ImmersiveMapPolygonStyle(),
                              polylineStyle: ImmersiveMapPolylineStyle = ImmersiveMapPolylineStyle(),
                              pointStyle: ImmersiveMapPointStyle = ImmersiveMapPointStyle(),
                              zoomRange: ClosedRange<Double> = 0 ... 30) -> ImmersiveMapLayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "geojson", subdirectory: "NYC") else {
            print("NYC/\(name).geojson is not in the bundle")
            return nil
        }
        do {
            return try ImmersiveMapLayer(id: name,
                                         geoJSON: Data(contentsOf: url),
                                         polygonStyle: polygonStyle,
                                         polylineStyle: polylineStyle,
                                         pointStyle: pointStyle,
                                         zoomRange: zoomRange)
        } catch {
            print("NYC/\(name).geojson: \(error)")
            return nil
        }
    }
}
