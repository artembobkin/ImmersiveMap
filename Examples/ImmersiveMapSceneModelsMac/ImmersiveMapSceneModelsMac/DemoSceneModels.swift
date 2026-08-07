// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// Demo 3D scene models: a real textured USDZ from the app bundle plus a
/// runtime-written OBJ obelisk. Two sources demonstrate mesh sharing (three
/// instances of one asset load one mesh) and mixed formats.
///
/// The USDZ is "Spot" by Keenan Crane, released into the public domain, see
/// `Resources/CREDITS.md`.
enum DemoSceneModels {
    static let spotByTheEiffelTower: UInt64 = 9001
    static let spotOverParis: UInt64 = 9002
    static let spotInTokyo: UInt64 = 9003
    static let obelisk: UInt64 = 9004

    static let paris = GeoCoordinate(latitude: 48.8570, longitude: 2.2952)
    static let tokyo = GeoCoordinate(latitude: 35.6595, longitude: 139.7005)
    static let dubai = GeoCoordinate(latitude: 25.1972, longitude: 55.2744)

    static func makeModels() -> [ImmersiveMapSceneModel] {
        var models: [ImmersiveMapSceneModel] = []
        if let spot = ImmersiveMapSceneModel.Source(resource: "spot", withExtension: "usdz") {
            // A landmark-sized cow by the Eiffel Tower.
            models.append(ImmersiveMapSceneModel(id: spotByTheEiffelTower,
                                                 source: spot,
                                                 coordinate: paris,
                                                 headingDegrees: -35,
                                                 fitDiameterMeters: 160))
            // Her sister flying over Paris: exercises altitude and pitch.
            models.append(ImmersiveMapSceneModel(id: spotOverParis,
                                                 source: spot,
                                                 coordinate: GeoCoordinate(latitude: 48.8615,
                                                                           longitude: 2.2890),
                                                 altitudeMeters: 260,
                                                 headingDegrees: 120,
                                                 pitchDegrees: 12,
                                                 fitDiameterMeters: 110))
            // Tokyo: the same source, so the mesh is loaded once and shared.
            models.append(ImmersiveMapSceneModel(id: spotInTokyo,
                                                 source: spot,
                                                 coordinate: tokyo,
                                                 headingDegrees: 30,
                                                 fitDiameterMeters: 220))
        }
        if let obeliskURL = writeObeliskOBJ() {
            // Dubai spire next to the Burj Khalifa, from a plain OBJ file URL.
            models.append(ImmersiveMapSceneModel(id: obelisk,
                                                 source: ImmersiveMapSceneModel.Source(url: obeliskURL),
                                                 coordinate: dubai,
                                                 fitDiameterMeters: 500))
        }
        return models
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
