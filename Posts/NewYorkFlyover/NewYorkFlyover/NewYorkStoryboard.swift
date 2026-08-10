// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// A single slow move over the north end of Central Park: the camera starts
/// high above Harlem Meer looking west-southwest across the park edge, then
/// glides down and in toward the Fifth Avenue corner while turning to
/// south-southwest. Both keyframes were framed by hand in the app with the
/// debug panel open; bearing and pitch are radians (the panel shows degrees).
enum NewYorkStoryboard {
    /// Start frame (debug panel: z 15.95, pitch 59.9 deg, bearing -115.3 deg).
    static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 40.800,
        longitudeDegrees: -73.959,  
        zoom: 15.95,
        bearing: -2.013,
        pitch: 1.046
    )

    /// End frame (debug panel: z 17.43, pitch 60.9 deg, bearing -153.9 deg).
    private static let target = ImmersiveMapCameraPosition(
        latitudeDegrees: 40.798,
        longitudeDegrees: -73.950,
        zoom: 17.43,
        bearing: -2.685,
        pitch: 1.063
    )

    static func makeShots() -> [ImmersiveMapCameraTourShot] {
        [ImmersiveMapCameraTourShot(
            position: target,
            options: CameraFlightOptions(duration: 20.0,
                                         routeStyle: .mercatorShortestPath,
                                         altitudeStyle: .direct),
            holdAfter: 1.0
        )]
    }
}
