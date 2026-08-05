// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapIOSApp: App {
    var body: some Scene {
        WindowGroup {
            MapScreen()
        }
    }
}

private struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var sceneModelsController = ImmersiveMapSceneModelsController()

    var body: some View {
        ImmersiveMapView()
            .cameraController(camera)
            .sceneModels(sceneModelsController)
            .enableCameraUIControls()
            .ignoresSafeArea()
            .task {
                DemoSceneModels.populate(sceneModelsController)
            }
    }
}

/// Demo 3D scene models. The demo asset is a runtime-written OBJ (an obelisk),
/// so the project needs no binary model resources: any local .usdz or .obj URL
/// works the same way through `ImmersiveMapSceneModel.Source`.
private enum DemoSceneModels {
    static func populate(_ controller: ImmersiveMapSceneModelsController) {
        guard let url = writeObeliskOBJ() else {
            return
        }
        let source = ImmersiveMapSceneModel.Source(url: url)
        controller.set([
            ImmersiveMapSceneModel(id: 9001,
                                   source: source,
                                   coordinate: GeoCoordinate(latitude: 35.6595, longitude: 139.7005),
                                   headingDegrees: 30,
                                   fitDiameterMeters: 350),
            ImmersiveMapSceneModel(id: 9002,
                                   source: source,
                                   coordinate: GeoCoordinate(latitude: 25.1972, longitude: 55.2744),
                                   fitDiameterMeters: 500),
            // A pitched obelisk hovering over Paris: exercises altitude and pitch.
            ImmersiveMapSceneModel(id: 9003,
                                   source: source,
                                   coordinate: GeoCoordinate(latitude: 48.8584, longitude: 2.2945),
                                   altitudeMeters: 150,
                                   pitchDegrees: 90,
                                   fitDiameterMeters: 120)
        ])
    }

    /// A tapered obelisk with a pyramid top: Y-up, base at y = 0 so the model
    /// stands on the map surface, 1 unit tall (sized via `fitDiameterMeters`).
    private static func writeObeliskOBJ() -> URL? {
        let obj = """
        v -0.08 0 -0.08
        v 0.08 0 -0.08
        v 0.08 0 0.08
        v -0.08 0 0.08
        v -0.06 0.75 -0.06
        v 0.06 0.75 -0.06
        v 0.06 0.75 0.06
        v -0.06 0.75 0.06
        v 0 1 0
        f 1 5 6
        f 1 6 2
        f 2 6 7
        f 2 7 3
        f 3 7 8
        f 3 8 4
        f 4 8 5
        f 4 5 1
        f 5 9 6
        f 6 9 7
        f 7 9 8
        f 8 9 5
        f 1 2 3
        f 1 3 4
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("immersive-map-demo-obelisk.obj")
        do {
            try obj.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
