// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// A sphere unrolling into a plane and rolling back up, with nothing else
/// happening on screen.
///
/// Every position shares one ground point and one bearing, so the map never
/// slides or turns under the camera: the only values the flights interpolate
/// are zoom, which is also the morph's only input, and the tilt that moves with
/// it. Nothing else is allowed to move, or the eye follows something other than
/// the change being demonstrated.
///
/// The tour stops twice on the way out, once halfway through the morph and once
/// after it has finished, and then runs the whole range backwards to close the
/// loop. The mid-morph hold is the frame worth having: a partially unrolled
/// sheet is the state most map engines never show, because they cut between a
/// sphere and a plane instead of interpolating.
///
/// The Ligurian coast is under the camera because the unrolling is easiest to
/// read against a coastline running across the frame: the curve of the horizon
/// straightens into it, and the coast is the only line in shot that does not.
/// Pitch and bearing are radians.
enum UnfurlStoryboard {
    private static let latitude = 43.5
    private static let longitude = 11.0
    /// The tilt is what makes the morph visible, and it moves.
    ///
    /// Straight down, a sphere and a plane project to almost the same picture:
    /// the map fills the frame either way, the change is a slow stretch at the
    /// edges, and the moment of unrolling passes unnoticed. The shape only
    /// shows at a grazing angle, where the sphere has a curved horizon cutting
    /// across the frame and the plane has a straight one.
    ///
    /// The camera therefore starts almost lying on its side, near the engine's
    /// 75 degree ceiling (`CameraSettings.maximumPitch`), and comes up as the
    /// world flattens: 73 degrees on the globe, 66 halfway through the morph,
    /// 57 once the map is a plane, and back down again on the return leg. The
    /// tilt moving with the zoom keeps the horizon in frame while its curvature
    /// leaves, which is the only thing in shot that should read as a change.
    private static let globePitch: Float = 1.28
    private static let halfwayPitch: Float = 1.16
    private static let flatPitch: Float = 1.00

    /// The whole globe in frame, well below the start of the morph.
    static let globe = position(zoom: 3.0, pitch: globePitch)

    /// Halfway through the morph: neither a sphere nor a plane.
    private static let halfway = position(zoom: UnfurlPresentation.midpointZoom,
                                          pitch: halfwayPitch)

    /// Past the end of the morph, fully flat.
    private static let flat = position(zoom: 9.0, pitch: flatPitch)

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

    private static func position(zoom: Double, pitch: Float) -> ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                   longitudeDegrees: longitude,
                                   zoom: zoom,
                                   bearing: 0,
                                   pitch: pitch)
    }
}
