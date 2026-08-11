// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// A crowd of fifty coming apart on the way down and back together on the way
/// out, over half a kilometre of Barcelona's Eixample.
///
/// The camera does one thing per shot and every shot is centred on the same
/// ground point, the middle of the densest knot (`CrowdPeople.eixample`). There
/// is nothing to travel over, so the flights interpolate only zoom, tilt and,
/// once, bearing: whatever moves in frame is the crowd rearranging itself, not
/// the map sliding under it.
///
/// The zooms are not chosen for the framing, they are the thresholds of the
/// collision layout converted back into camera state. A flower forms when neighbouring
/// anchors come within 0.35 marker widths of each other, and with the post's
/// marker size that radius is worth about
///
/// - 168 m of ground at zoom 12.6, which is more than the 133 m Cerdà block:
///   every person is connected to the next and the whole crowd is one flower;
/// - 32 m at zoom 15.0, which is wider than a knot (22 m) and much narrower
///   than a block: the five knots are five flowers and the fifteen individuals
///   stand on their own;
/// - 6.4 m at zoom 17.3, which is narrower than the crowd's median gap of
///   9.2 m: nobody groups, and the people who still overlap are pushed apart as
///   circles with a cone back to the doorway they are actually standing in.
///
/// The last one is why the street shot is at 17.3 rather than at the 16.8 the
/// framing would prefer. A tilted camera foreshortens ground distance along the
/// view axis by cos(pitch), so at 58 degrees the grouping neighbourhood is an
/// ellipse almost twice as long as it is wide, and at 16.8 two of the knots
/// stay grouped inside it. Half a zoom level closer in, no part of the crowd is
/// dense enough to hold a flower together in any direction.
///
/// So the storyboard is a single continuous zoom through those three states and
/// back, with an orbit at the bottom to show that the markers are pinned to the
/// ground rather than to the screen. Pitch and bearing are radians.
enum CrowdStoryboard {
    private static let latitude = CrowdPeople.eixample.latitude
    private static let longitude = CrowdPeople.eixample.longitude

    /// The bearing that squares the Eixample grid in frame, held from the first
    /// city shot onwards. See `CrowdPeople.gridBearing`.
    private static let grid = CrowdPeople.gridBearing

    /// A 24 degree swing around the crowd at street level. Small on purpose:
    /// enough parallax for the blocks to move against each other, little enough
    /// that the same faces stay in frame throughout.
    private static let orbit = grid + 0.42

    /// The whole planet, centred on Barcelona, bearing north. The twelve people
    /// who are not in Spain are the point of this shot, and the crowd itself is
    /// one flower on the Mediterranean coast.
    static let globe = ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                  longitudeDegrees: longitude,
                                                  zoom: 1.6,
                                                  bearing: 0,
                                                  pitch: 0)

    /// The city, one flower. The frame is about 4.5 km tall here, so the crowd
    /// is a tenth of it: a single ring of seven portraits (the other
    /// forty-three are inside it and hidden, `AvatarCollisionMath.maxFlowerPetals`)
    /// in the middle of a grid it does not yet resolve into.
    private static let city = position(zoom: 12.6, bearing: grid, pitch: 0.35)

    /// The neighbourhood, five flowers. The frame is a kilometre tall, the
    /// blocks are readable, and the knots have separated from each other while
    /// staying grouped inside themselves.
    private static let neighbourhood = position(zoom: 15.0, bearing: grid, pitch: 0.70)

    /// The street. Everyone is a portrait of their own, standing among extruded
    /// buildings at 58 degrees of tilt, with cones from the few that still have
    /// to give way.
    private static let street = position(zoom: 17.3, bearing: grid, pitch: 1.02)

    /// The same street from 24 degrees around it.
    private static let streetTurned = position(zoom: 17.3, bearing: orbit, pitch: 1.02)

    /// The way out: the city again, from the orbited bearing, so the turn is
    /// not unwound twice.
    private static let cityTurned = position(zoom: 12.6, bearing: orbit, pitch: 0.35)

    static func makeShots() -> [ImmersiveMapCameraTourShot] {
        [
            // Out of the sphere and onto the city. The bearing turns from north
            // to the grid during the descent, so the blocks are already square
            // by the time they are big enough to read.
            ImmersiveMapCameraTourShot(position: city,
                                       options: ramp(duration: 8.0),
                                       holdAfter: 1.5),
            // The flower splits into five. The hold is where the petals land.
            ImmersiveMapCameraTourShot(position: neighbourhood,
                                       options: ramp(duration: 6.0),
                                       holdAfter: 1.5),
            // The five come apart into fifty.
            ImmersiveMapCameraTourShot(position: street,
                                       options: ramp(duration: 6.0),
                                       holdAfter: 1.0),
            // Bearing only: the crowd stays where it is standing while the city
            // turns around it.
            ImmersiveMapCameraTourShot(position: streetTurned,
                                       options: ramp(duration: 7.0),
                                       holdAfter: 1.0),
            // Back out, and the whole layout runs in reverse: fifty into five
            // into one.
            ImmersiveMapCameraTourShot(position: cityTurned,
                                       options: ramp(duration: 6.5),
                                       holdAfter: 1.0),
            // Home to the globe in one move, so a looped preview and a rendered
            // lap both close without a jump.
            ImmersiveMapCameraTourShot(position: globe,
                                       options: ramp(duration: 8.0),
                                       holdAfter: 2.0),
        ]
    }

    /// A straight ramp. `.direct` altitude because the cinematic arc gains
    /// height before it descends, and there is no height to gain from a globe
    /// or to lose over a target the camera is already centred on; the route
    /// style has nothing to interpolate, because every shot shares one ground
    /// point.
    private static func ramp(duration: TimeInterval) -> CameraFlightOptions {
        CameraFlightOptions(duration: duration,
                            routeStyle: .mercatorShortestPath,
                            altitudeStyle: .direct)
    }

    private static func position(zoom: Double,
                                 bearing: Float,
                                 pitch: Float) -> ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                   longitudeDegrees: longitude,
                                   zoom: zoom,
                                   bearing: bearing,
                                   pitch: pitch)
    }
}
