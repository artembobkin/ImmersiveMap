// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The horizon band: CPU mirror of `horizonBandStationAngle` in
/// Horizon.metal, the angles above the edge the band's vertices sit at.
/// The band is strung between the rim's far cutoff under the edge and the
/// top the resolver chose (`HorizonHaze.bandTopRadians`), with the edge
/// itself a station and one either side of it at least four feather widths
/// out, so the feather's ramp gets its own quads. A running maximum keeps the stations in order whatever the
/// widths: a wide feather on a small drawable can never fold a quad over
/// the previous one. And every station stays on the sphere of directions:
/// low over the planet the glow reaches its 45 degree cap, and five of
/// those would carry the outer station past the zenith and fold the band
/// back over itself.
enum HorizonBandMath {
    static let stationCount = 8
    /// How many azimuths the band is split into around the local vertical.
    static let segmentCount = 128

    static func stationAngles(haze: HorizonHaze) -> [Float] {
        let feather = haze.featherRadians * 4
        let raw: [Float] = [
            -haze.cutoffEndRadians,
            -haze.cutoffStartRadians,
            -max(haze.groundBandRadians, feather),
            0,
            max(haze.bandRadians, feather),
            haze.bandRadians * 3,
            haze.glowRadians,
            haze.bandTopRadians
        ]
        let limit = Float.pi / 2 - 1e-3
        var angles: [Float] = []
        var running = raw[0]
        for angle in raw {
            running = max(running, angle)
            angles.append(min(max(running, haze.edge.depression - limit), haze.edge.depression + limit))
        }
        return angles
    }
}
