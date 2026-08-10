// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// A sphere unrolling into a plane and rolling back up, with nothing else
/// happening on screen.
///
/// Every position shares one ground point, one bearing and one pitch, so the
/// only value the flights interpolate is zoom, and zoom is the only input the
/// morph has. Anything else in motion, a pan, a turn, a tilt, would give the
/// eye something to follow that is not the change being demonstrated.
///
/// The tour stops twice on the way out, once halfway through the morph and once
/// after it has finished, and then runs the whole range backwards to close the
/// loop. The mid-morph hold is the frame worth having: a partially unrolled
/// sheet is the state most map engines never show, because they cut between a
/// sphere and a plane instead of interpolating.
///
/// The Ligurian coast is under the camera because the unrolling is easiest to
/// read against a coastline running across the frame: the curve of the horizon
/// straightens into it. Pitch and bearing are radians.
enum UnfurlStoryboard {
    private static let latitude = 43.5
    private static let longitude = 11.0
    /// Held across the whole tour. Enough tilt to see the sphere as a sphere,
    /// little enough that the flat map at the end is still legible.
    private static let pitch: Float = 0.35

    /// The whole globe in frame, well below the start of the morph.
    static let globe = position(zoom: 3.0)

    /// Halfway through the morph: neither a sphere nor a plane.
    private static let halfway = position(zoom: UnfurlPresentation.midpointZoom)

    /// Past the end of the morph, fully flat.
    private static let flat = position(zoom: 9.0)

    static func makeShots() -> [ImmersiveMapCameraTourShot] {
        [
            ImmersiveMapCameraTourShot(position: halfway,
                                       options: ramp(duration: 9.0),
                                       holdAfter: 2.5),
            ImmersiveMapCameraTourShot(position: flat,
                                       options: ramp(duration: 8.0),
                                       holdAfter: 2.0),
            // Back to the start in one move, so a looped preview and a rendered
            // lap both close without a jump.
            ImmersiveMapCameraTourShot(position: globe,
                                       options: ramp(duration: 11.0),
                                       holdAfter: 2.0),
        ]
    }

    /// A straight zoom ramp. `.direct` altitude because the cinematic arc
    /// climbs before it descends, and any climb here would drive the morph
    /// backwards mid-shot; the route style has nothing to interpolate, because
    /// every shot starts and ends on the same ground point.
    private static func ramp(duration: TimeInterval) -> CameraFlightOptions {
        CameraFlightOptions(duration: duration,
                            routeStyle: .mercatorShortestPath,
                            altitudeStyle: .direct)
    }

    private static func position(zoom: Double) -> ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                   longitudeDegrees: longitude,
                                   zoom: zoom,
                                   bearing: 0,
                                   pitch: pitch)
    }
}
