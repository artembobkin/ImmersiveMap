// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// A straight drop out of orbit onto the colonnade of the Altes Museum.
///
/// Every position here shares one latitude, one longitude and one bearing, and
/// that is the whole trick. A flight interpolates the ground point as well as
/// the zoom, so a globe centred anywhere other than the target spends the
/// descent travelling sideways: from a sphere that reads as skimming along the
/// surface rather than falling towards it. With the globe already centred on
/// the target there is no ground distance left to cover, nothing is left for
/// the route style to interpolate, and the only things that move are the
/// altitude and, at the end, the tilt.
///
/// The target is the Altes Museum on Museumsinsel, whose eighteen Ionic columns
/// face south across the Lustgarten. That is why the whole storyboard holds
/// bearing 0, looking due north: the camera comes down in front of the
/// colonnade instead of having to turn towards it, with the Berliner Dom to the
/// right and the Spree behind. Pitch is in radians (the debug panel shows
/// degrees).
enum BerlinStoryboard {
    /// The one ground point the whole descent is pinned to.
    private static let latitude = 52.51972
    private static let longitude = 13.39806

    /// The establishing globe, already centred on Berlin.
    static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: latitude,
        longitudeDegrees: longitude,
        zoom: 1.3,
        bearing: 0,
        pitch: 0
    )

    /// Out of the sphere and over the city, still looking straight down so the
    /// fall stays vertical while it covers most of the altitude.
    private static let overCity = ImmersiveMapCameraPosition(
        latitudeDegrees: latitude,
        longitudeDegrees: longitude,
        zoom: 12.6,
        bearing: 0,
        pitch: 0
    )

    /// In front of the colonnade (debug panel: z 18.0, pitch 60.2 deg,
    /// bearing 0 deg).
    private static let colonnade = ImmersiveMapCameraPosition(
        latitudeDegrees: latitude,
        longitudeDegrees: longitude,
        zoom: 18.0,
        bearing: 0,
        pitch: 1.05
    )

    static func makeShots() -> [ImmersiveMapCameraTourShot] {
        [
            // `.direct` altitude, not the cinematic arc: the arc gains height
            // before it descends, and there is no height left to gain from a
            // globe. The route style has nothing to do here, because start and
            // end sit on the same point.
            ImmersiveMapCameraTourShot(
                position: overCity,
                options: CameraFlightOptions(duration: 10.0,
                                             routeStyle: .mercatorShortestPath,
                                             altitudeStyle: .direct)
            ),
            // The last five zoom levels, and the only shot that tilts: the
            // camera drops the rest of the way and lies back into the facade as
            // it arrives.
            ImmersiveMapCameraTourShot(
                position: colonnade,
                options: CameraFlightOptions(duration: 13.0,
                                             routeStyle: .mercatorShortestPath,
                                             altitudeStyle: .direct),
                holdAfter: 2.5
            ),
        ]
    }
}
