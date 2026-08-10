// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// One fall out of orbit into the middle of Berlin.
///
/// The camera opens on the globe with Europe turned towards it, drops straight
/// onto the city, and finishes low over Mitte with the historic centre ahead of
/// it: Museumsinsel and the Berliner Dom, the Lustgarten, Unter den Linden
/// running west towards the Brandenburg Gate.
///
/// The move is cut in two shots that share a bearing, so it reads as one
/// continuous fall rather than a flight with a turn in it. The first covers the
/// distance, the second spends its whole length on the last two zoom levels,
/// where the extruded blocks come up out of the plane. Bearing and pitch are
/// radians (the debug panel shows degrees), and both frames are meant to be
/// re-framed by hand in the app with the panel open before a final render.
enum BerlinStoryboard {
    /// The establishing globe. Centred south of Berlin so the city sits high on
    /// the lit face of the sphere rather than on the horizon.
    static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 41.0,
        longitudeDegrees: 13.4,
        zoom: 1.3,
        bearing: 0,
        pitch: 0
    )

    /// Out of the sphere and over the city, still flat on and high enough to
    /// hold the whole of Berlin (debug panel: z 11.8, pitch 17.2 deg,
    /// bearing 24.1 deg).
    private static let approach = ImmersiveMapCameraPosition(
        latitudeDegrees: 52.5080,
        longitudeDegrees: 13.3900,
        zoom: 11.8,
        bearing: 0.42,
        pitch: 0.30
    )

    /// Low over Mitte, looking north-east into Museumsinsel (debug panel:
    /// z 16.7, pitch 60.2 deg, bearing 24.1 deg).
    private static let mitte = ImmersiveMapCameraPosition(
        latitudeDegrees: 52.5128,
        longitudeDegrees: 13.3948,
        zoom: 16.7,
        bearing: 0.42,
        pitch: 1.05
    )

    static func makeShots() -> [ImmersiveMapCameraTourShot] {
        [
            // `.direct` altitude, not the cinematic arc: the arc gains height
            // first, and there is no height left to gain from a globe. The
            // great circle keeps the ground track honest over that distance.
            ImmersiveMapCameraTourShot(
                position: approach,
                options: CameraFlightOptions(duration: 11.0,
                                             routeStyle: .greatCircle,
                                             altitudeStyle: .direct)
            ),
            // Short on the map, long in time: the ground is close now, so the
            // same seconds buy far less distance and the descent slows down of
            // its own accord.
            ImmersiveMapCameraTourShot(
                position: mitte,
                options: CameraFlightOptions(duration: 13.0,
                                             routeStyle: .mercatorShortestPath,
                                             altitudeStyle: .direct),
                holdAfter: 2.0
            ),
        ]
    }
}
