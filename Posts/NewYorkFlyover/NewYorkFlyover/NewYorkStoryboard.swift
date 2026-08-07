// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// Slow cinematic flyover of Manhattan's skyscrapers, built for a social video
/// post: a harbor-wide skyline establish, a dive to One World Trade Center,
/// a low glide up the island to the Empire State Building, a drift to
/// Billionaires' Row at Central Park, and a pull-back to the establishing
/// frame so the reel loops seamlessly.
enum NewYorkStoryboard {
    /// Establishing frame and loop seam: the Lower Manhattan skyline seen from
    /// above the Upper Bay (the camera sits south of the centered point and
    /// looks north across the water). Kept at zoom 14.3: building extrusion
    /// only exists on tiles of zoom 13 and above, and under this much pitch
    /// the demanded tiles reach zoom 13 only from about camera zoom 14; any
    /// wider and the skyline establishes flat.
    static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 40.708,
        longitudeDegrees: -74.011,
        zoom: 14.3,
        bearing: 0.03,
        pitch: 1.13
    )

    // The shots' heroes.
    private static let oneWorldTrade = (lat: 40.7127, lon: -74.0134)
    private static let empireState = (lat: 40.7484, lon: -73.9857)
    private static let billionairesRow = (lat: 40.7655, lon: -73.9765)

    static func makeShots() -> [ImmersiveMapCameraTourShot] {
        var shots: [ImmersiveMapCameraTourShot] = []

        // 1. Slow dive from the harbor down to One World Trade Center, ending
        // slightly rotated so the tower reads against the Hudson. Street
        // shots stay at zoom 15.3-15.4: any closer under this much pitch and
        // the camera ends up between the tower walls instead of above them.
        let oneWorldTradeStreet = ImmersiveMapCameraPosition(
            latitudeDegrees: oneWorldTrade.lat,
            longitudeDegrees: oneWorldTrade.lon,
            zoom: 15.3,
            bearing: 0.35,
            pitch: 1.1
        )
        shots.append(ImmersiveMapCameraTourShot(
            position: oneWorldTradeStreet,
            options: CameraFlightOptions(duration: 11.0, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.5
        ))

        // 2. A gentle partial turntable around One World Trade Center.
        shots.append(contentsOf: partialOrbit(base: oneWorldTradeStreet,
                                              stepRadians: Double.pi / 3,
                                              segments: 2,
                                              perSegmentDuration: 7.5))

        // 3. Low glide north along the island to the Empire State Building:
        // the long "flying over the rooftops" shot.
        let empireStateStreet = ImmersiveMapCameraPosition(
            latitudeDegrees: empireState.lat,
            longitudeDegrees: empireState.lon,
            zoom: 15.4,
            bearing: -0.25,
            pitch: 1.05
        )
        shots.append(ImmersiveMapCameraTourShot(
            position: empireStateStreet,
            options: CameraFlightOptions(duration: 13.0, routeStyle: .mercatorShortestPath, altitudeStyle: .direct),
            holdAfter: 0.4
        ))

        // 4. A slow partial turntable around the Empire State Building.
        shots.append(contentsOf: partialOrbit(base: empireStateStreet,
                                              stepRadians: Double.pi / 3,
                                              segments: 2,
                                              perSegmentDuration: 7.5))

        // 5. Drift north to Billionaires' Row, looking up the supertalls with
        // Central Park opening behind them.
        shots.append(ImmersiveMapCameraTourShot(
            position: ImmersiveMapCameraPosition(latitudeDegrees: billionairesRow.lat,
                                                 longitudeDegrees: billionairesRow.lon,
                                                 zoom: 15.3,
                                                 bearing: 0.1,
                                                 pitch: 1.1),
            options: CameraFlightOptions(duration: 10.0, routeStyle: .mercatorShortestPath, altitudeStyle: .direct),
            holdAfter: 0.5
        ))

        // 6. Pull back and south to the establishing skyline frame: the loop
        // seam for a seamless repeat.
        shots.append(ImmersiveMapCameraTourShot(
            position: overview,
            options: CameraFlightOptions(duration: 12.0, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 1.0
        ))

        return shots
    }

    /// A slow partial fly-around of a point: each segment turns by
    /// `stepRadians` (kept well under 180 degrees so the flight turns the
    /// intended way).
    private static func partialOrbit(base: ImmersiveMapCameraPosition,
                                     stepRadians: Double,
                                     segments: Int,
                                     perSegmentDuration: TimeInterval) -> [ImmersiveMapCameraTourShot] {
        (1...segments).map { index in
            let bearing = base.bearing + Float(stepRadians) * Float(index)
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
