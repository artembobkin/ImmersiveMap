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
    /// New York's open data: every file registered, each drawn by a layer.
    @State private var layers = NewYorkLayers.makeController()

    var body: some View {
        ImmersiveMapView()
            .modelArchive(ImmersiveMapTilesService.modelArchiveURL)
            .cameraPosition(.city(.newYork))
            .layers(layers)
    }
}

/// New York City's open data as layers, from the GeoJSON files of the `NYC`
/// folder in the app's bundle: the boroughs, the neighbourhoods, the parks,
/// the bike routes, and the subway's lines and stations. An example of the
/// layers API on real data: each file is registered as a source under its
/// name, and a layer draws it with a style and a zoom range. A file is read
/// when its layer first draws, off the main thread, so the neighbourhoods
/// and the bike routes cost nothing until the camera is near enough to
/// show them. The boroughs and the subway's lines draw from the globe on,
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
                              polygonStyle: ImmersiveMapPolygonStyle(fillColor: SIMD4(0.20, 0.65, 0.30, 0.45),
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
