// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One camera pose, in the units both engines accept once converted: degrees
/// for the angles, a 512 px Mercator zoom (both engines pick tile level
/// `floor(zoom)`, so equal zooms load the same tile levels).
struct BenchPose: Sendable {
    let latitude: Double
    let longitude: Double
    let zoom: Double
    /// Degrees clockwise from north.
    let bearing: Double
    /// Degrees from straight down.
    let pitch: Double
}

struct BenchShot: Sendable {
    let name: String
    let pose: BenchPose
    let duration: TimeInterval
    let holdAfter: TimeInterval
}

/// The scripted run both engines replay. Same poses, same durations, same
/// order; the engine is the only variable.
enum BenchScenario {
    /// Where every run starts: a globe view, well above the flat transition.
    static let establish = BenchPose(latitude: 30, longitude: 0, zoom: 2, bearing: 0, pitch: 0)

    /// Seconds the map is given after creation before anything is measured:
    /// style load, first tiles, atlas uploads.
    static let warmUp: TimeInterval = 8

    /// Cinematic city tour: dense downtowns at street zoom with tilt, chained
    /// by long flights so both tile loading and steady rendering are on the
    /// clock.
    static let tour: [BenchShot] = [
        BenchShot(name: "manhattan",
                  pose: BenchPose(latitude: 40.7484, longitude: -73.9857, zoom: 15.5, bearing: 30, pitch: 55),
                  duration: 6, holdAfter: 2),
        BenchShot(name: "berlin",
                  pose: BenchPose(latitude: 52.5194, longitude: 13.3985, zoom: 16, bearing: -40, pitch: 60),
                  duration: 6, holdAfter: 2),
        BenchShot(name: "paris",
                  pose: BenchPose(latitude: 48.8584, longitude: 2.2945, zoom: 14, bearing: 0, pitch: 45),
                  duration: 5, holdAfter: 2),
        BenchShot(name: "tokyo",
                  pose: BenchPose(latitude: 35.6896, longitude: 139.6917, zoom: 16.5, bearing: 90, pitch: 60),
                  duration: 6, holdAfter: 2),
        BenchShot(name: "globe",
                  pose: BenchPose(latitude: 20, longitude: 100, zoom: 2.5, bearing: 0, pitch: 0),
                  duration: 4, holdAfter: 1),
    ]

    /// Programmatic pan: the camera is set on every display tick, the way a
    /// drag gesture drives it, sliding east across Midtown while rotating.
    /// Tiles stream in continuously for the whole window.
    static let panDuration: TimeInterval = 20
    static let panStart = BenchPose(latitude: 40.7484, longitude: -73.9857, zoom: 15.5, bearing: 30, pitch: 55)

    static func panPose(progress: Double) -> BenchPose {
        let p = min(max(progress, 0), 1)
        return BenchPose(latitude: panStart.latitude + 0.012 * p,
                         longitude: panStart.longitude + 0.035 * p,
                         zoom: panStart.zoom,
                         bearing: panStart.bearing + 90 * p,
                         pitch: panStart.pitch)
    }

    /// Idle: the same Midtown pose, nothing moving, after a settle period.
    static let idleSettle: TimeInterval = 4
    static let idleDuration: TimeInterval = 10
}
