// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// Demo reel storyboard: globe, flyover, morph into a city, orbit, loop.
enum CinematicStoryboard {
    /// Departure point and loop return point (the whole globe).
    static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 25,
        longitudeDegrees: -30,
        zoom: 1.7,
        bearing: 0,
        pitch: 0.08
    )

    // The shots' heroes: dense buildings, recognizable silhouettes.
    private static let tokyo = (lat: 35.6595, lon: 139.7005)
    private static let dubai = (lat: 25.1972, lon: 55.2744)

    static func makeShots() -> [ImmersiveMapCameraTourShot] {
        var shots: [ImmersiveMapCameraTourShot] = []

        // 1. A great-circle sweep toward Tokyo: the globe visibly rotates.
        shots.append(ImmersiveMapCameraTourShot(
            position: ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                 longitudeDegrees: tokyo.lon,
                                                 zoom: 4.0, bearing: 0, pitch: 0.2),
            options: CameraFlightOptions(duration: 3.8, routeStyle: .greatCircle, altitudeStyle: .direct),
            holdAfter: 0.5
        ))

        // The globe <-> plane morph window at Tokyo's latitude: z6.0..z7.3
        // (automaticTransitionStartZoom 6.0, span 1.0 plus the latitude addition
        // log2(1/cos(35.7°)) ~= 0.3). For the morph to be visible under heavy
        // tilt, the tilt is gained BEFORE the window, and the window itself is crossed
        // by a slow separate flight with a constant pitch.

        // 2. Tilt while still on the globe, just below the morph window: 1.28 rad (~73°),
        // almost the camera maximum (75°).
        let tokyoPreTilt = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                      longitudeDegrees: tokyo.lon,
                                                      zoom: 5.6, bearing: 0.25, pitch: 1.28)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoPreTilt,
            options: CameraFlightOptions(duration: 2.2, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.2
        ))

        // 3. A slow pass through the entire morph window under full tilt:
        // the globe unfurls into a plane right in perspective
        // (the promo's key shot).
        let tokyoMorphIn = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                      longitudeDegrees: tokyo.lon,
                                                      zoom: 7.6, bearing: 0.45, pitch: 1.28)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoMorphIn,
            options: CameraFlightOptions(duration: 5.0, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.4
        ))

        // 4. Diving down to the streets: buildings rise up.
        let tokyoStreet = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                     longitudeDegrees: tokyo.lon,
                                                     zoom: 16.7, bearing: 0.55, pitch: 1.02)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoStreet,
            options: CameraFlightOptions(duration: 2.8, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.7
        ))

        // 5. Turntable around Tokyo's buildings.
        shots.append(contentsOf: orbit(base: tokyoStreet, segments: 3, perSegmentDuration: 2.3))

        // 6. Climb out of the streets back to the top edge of the morph window, tilt
        // is preserved.
        let tokyoPullUp = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                     longitudeDegrees: tokyo.lon,
                                                     zoom: 7.6, bearing: -0.35, pitch: 1.28)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoPullUp,
            options: CameraFlightOptions(duration: 3.0, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.2
        ))

        // 7. A slow reverse morph: the plane folds back into the globe under
        // the same tilt.
        let tokyoMorphOut = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                       longitudeDegrees: tokyo.lon,
                                                       zoom: 5.6, bearing: -0.55, pitch: 1.28)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoMorphOut,
            options: CameraFlightOptions(duration: 5.0, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.4
        ))

        // 8. A long flight pulling out to the globe and a new dive into Dubai.
        // Pitch interpolates from the tilted pull-out: at the arc's apex the
        // low-zoom constraints will clamp it, and on approach the tilt returns.
        let dubaiStreet = ImmersiveMapCameraPosition(latitudeDegrees: dubai.lat,
                                                     longitudeDegrees: dubai.lon,
                                                     zoom: 16.4, bearing: -0.35, pitch: 1.0)
        shots.append(ImmersiveMapCameraTourShot(
            position: dubaiStreet,
            options: CameraFlightOptions(duration: 6.0, routeStyle: .greatCircle, altitudeStyle: .overviewFirst),
            holdAfter: 0.7
        ))

        // 9. Turntable around Dubai.
        shots.append(contentsOf: orbit(base: dubaiStreet, segments: 3, perSegmentDuration: 2.3))

        // 10. Return to the globe at the departure point: a seamless loop seam.
        shots.append(ImmersiveMapCameraTourShot(
            position: overview,
            options: CameraFlightOptions(duration: 4.6, routeStyle: .greatCircle, altitudeStyle: .overviewFirst),
            holdAfter: 0.8
        ))

        return shots
    }

    /// Splits a full revolution into equal segments (each under 180 degrees
    /// so the flight turns the intended way), giving a circular flyaround of a point.
    private static func orbit(base: ImmersiveMapCameraPosition,
                              segments: Int,
                              perSegmentDuration: TimeInterval) -> [ImmersiveMapCameraTourShot] {
        let step = Float(2.0 * Double.pi / Double(segments))
        return (1...segments).map { index in
            let bearing = base.bearing + step * Float(index)
            return ImmersiveMapCameraTourShot(
                position: ImmersiveMapCameraPosition(latitudeDegrees: base.latitudeDegrees,
                                                     longitudeDegrees: base.longitudeDegrees,
                                                     zoom: base.zoom,
                                                     bearing: bearing,
                                                     pitch: base.pitch),
                options: CameraFlightOptions(duration: perSegmentDuration,
                                             routeStyle: .mercatorShortestPath,
                                             altitudeStyle: .direct),
                holdAfter: 0
            )
        }
    }
}
