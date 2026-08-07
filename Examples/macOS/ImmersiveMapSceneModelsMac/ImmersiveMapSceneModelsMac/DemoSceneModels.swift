// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// Demo 3D scene models: one textured USDZ asset from the app bundle placed in
/// two cities. Three instances of the same source demonstrate mesh sharing:
/// the mesh is loaded once and drawn per instance.
///
/// The USDZ is "Spot" by Keenan Crane, released into the public domain, see
/// `Resources/CREDITS.md`.
enum DemoSceneModels {
    static let spotByTheEiffelTower: UInt64 = 9001
    static let spotOverParis: UInt64 = 9002
    static let spotInSeoul: UInt64 = 9003

    static let paris = GeoCoordinate(latitude: 48.8570, longitude: 2.2952)
    static let seoul = GeoCoordinate(latitude: 37.5735, longitude: 126.9769)

    static func makeModels() -> [ImmersiveMapSceneModel] {
        guard let spot = ImmersiveMapSceneModel.Source(resource: "spot", withExtension: "usdz") else {
            return []
        }
        return [
            // A landmark-sized cow by the Eiffel Tower.
            ImmersiveMapSceneModel(id: spotByTheEiffelTower,
                                   source: spot,
                                   coordinate: paris,
                                   headingDegrees: -35,
                                   fitDiameterMeters: 160),
            // Her sister flying over Paris: exercises altitude and pitch.
            ImmersiveMapSceneModel(id: spotOverParis,
                                   source: spot,
                                   coordinate: GeoCoordinate(latitude: 48.8615,
                                                             longitude: 2.2890),
                                   altitudeMeters: 260,
                                   headingDegrees: 120,
                                   pitchDegrees: 12,
                                   fitDiameterMeters: 110),
            // Seoul, on Gwanghwamun Square: the same source, so the mesh is
            // loaded once and shared with the Paris cows.
            ImmersiveMapSceneModel(id: spotInSeoul,
                                   source: spot,
                                   coordinate: seoul,
                                   headingDegrees: 30,
                                   fitDiameterMeters: 220),
        ]
    }
}
