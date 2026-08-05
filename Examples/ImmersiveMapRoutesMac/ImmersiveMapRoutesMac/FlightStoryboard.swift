// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// The journey the example flies: three legs around the world, each drawn as a
/// route while a biplane travels along it and the camera travels with them.
///
/// The legs are picked to cover the awkward cases on purpose: one crosses the
/// pole, one crosses the antimeridian, and the last one closes the loop.
enum FlightStoryboard {
    /// Routes are drawn in globe presentation, so the journey starts from an
    /// overview of the whole globe.
    static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 40,
        longitudeDegrees: 10,
        zoom: 1.6
    )

    struct Leg {
        let title: String
        let from: GeoCoordinate
        let to: GeoCoordinate
        let color: SIMD4<Float>
        /// Height of the arc at its apex. A real cruising altitude of 10 km is
        /// invisible against a 6371 km radius, so the arc is exaggerated: this
        /// is expressiveness, not physics.
        let peakAltitudeMeters: Double
        let seconds: TimeInterval

        var path: ImmersiveMapGeoPath {
            ImmersiveMapGeoPath(from: from, to: to, peakAltitudeMeters: peakAltitudeMeters)
        }
    }

    private static let moscow = GeoCoordinate(latitude: 55.7558, longitude: 37.6173)
    private static let sanFrancisco = GeoCoordinate(latitude: 37.7749, longitude: -122.4194)
    private static let seoul = GeoCoordinate(latitude: 37.5665, longitude: 126.9780)

    static let legs: [Leg] = [
        Leg(title: "Moscow to San Francisco",
            from: moscow,
            to: sanFrancisco,
            color: SIMD4<Float>(1.0, 0.36, 0.24, 1.0),
            peakAltitudeMeters: 520_000,
            seconds: 9),
        Leg(title: "San Francisco to Seoul",
            from: sanFrancisco,
            to: seoul,
            color: SIMD4<Float>(1.0, 0.82, 0.25, 1.0),
            peakAltitudeMeters: 460_000,
            seconds: 8),
        Leg(title: "Seoul to Moscow",
            from: seoul,
            to: moscow,
            color: SIMD4<Float>(0.32, 0.86, 1.0, 1.0),
            peakAltitudeMeters: 480_000,
            seconds: 8)
    ]

    // MARK: - Style

    /// The leg still to be flown is drawn dashed underneath the solid line that
    /// grows along it: the plan ahead, and the track behind.
    static let plannedDash = ImmersiveMapRouteDash(dashPoints: 5, gapPoints: 5)
    static let plannedColor = SIMD4<Float>(1.0, 1.0, 1.0, 0.45)
    static let plannedWidthPoints: Double = 1.5
    static let flownWidthPoints: Double = 2.5

    /// The camera rides along without touching the zoom, so scale stays with the
    /// user, and turns to the course so the direction of travel is up the screen.
    static let cameraFollow = ImmersiveMapCameraFollowOptions(bearing: .course,
                                                              smoothingHalfLife: 0.5)

    // MARK: - Scene

    static let planeModelId: UInt64 = 1
    /// Diameter of the plane in meters. On an overview globe a pixel is tens of
    /// kilometres, so a real wingspan would be subpixel.
    static let planeDiameterMeters: Double = 700_000

    static func flownRouteId(for index: Int) -> UInt64 {
        UInt64(100 + index)
    }

    static func plannedRouteId(for index: Int) -> UInt64 {
        UInt64(200 + index)
    }

    /// The bundled CC0 biplane. See `Resources/CREDITS.md`.
    static func planeSource() -> ImmersiveMapSceneModel.Source? {
        ImmersiveMapSceneModel.Source(resource: "biplane", withExtension: "obj")
    }
}
