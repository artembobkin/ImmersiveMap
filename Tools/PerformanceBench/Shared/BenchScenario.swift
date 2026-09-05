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

/// One scripted run: the same four windows (warm-up, tour, pan, idle) with
/// scenario-specific poses. `BENCH_SCENARIO` picks one by name.
struct BenchScenarioScript: Sendable {
    let name: String
    /// Where the run starts, jumped to before the warm-up.
    let establish: BenchPose
    /// Seconds the map is given after creation before anything is measured:
    /// style load, first tiles, atlas uploads.
    let warmUp: TimeInterval
    let tour: [BenchShot]
    /// Programmatic pan: the camera is set from a strict timer at the
    /// display rate, the cadence a drag gesture delivers.
    let panDuration: TimeInterval
    let panStart: BenchPose
    let panPose: @Sendable (Double) -> BenchPose
    /// Idle: the pan's end pose, nothing moving, after a settle period.
    let idleSettle: TimeInterval
    let idleDuration: TimeInterval
}

/// The scripted runs both engines replay. Same poses, same durations, same
/// order; the engine is the only variable within a scenario.
enum BenchScenario {
    /// Where the default scripts start: a globe view, well above the flat
    /// transition. Also the initial camera an engine is built with, before
    /// the host jumps to its script's own establish.
    static let establish = BenchPose(latitude: 30, longitude: 0, zoom: 2, bearing: 0, pitch: 0)

    static func script(named name: String) -> BenchScenarioScript? {
        switch name {
        case "full": return full
        case "globe": return globe
        case "globe0": return globe0
        case "globe16": return globe16
        case "flat9": return flat9
        default: return nil
        }
    }

    /// The default mixed session: dense downtowns at street zoom with tilt,
    /// chained by long flights, so both tile loading and steady rendering are
    /// on the clock, then a street-zoom pan and an idle street map.
    static let full = BenchScenarioScript(
        name: "full",
        establish: establish,
        warmUp: 8,
        tour: [
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
        ],
        panDuration: 20,
        panStart: fullPanStart,
        panPose: { progress in
            // Sliding east across Midtown while rotating; tiles stream in
            // continuously for the whole window.
            let p = min(max(progress, 0), 1)
            return BenchPose(latitude: fullPanStart.latitude + 0.012 * p,
                             longitude: fullPanStart.longitude + 0.035 * p,
                             zoom: fullPanStart.zoom,
                             bearing: fullPanStart.bearing + 90 * p,
                             pitch: fullPanStart.pitch)
        },
        idleSettle: 4,
        idleDuration: 10
    )

    /// The sphere only: every pose stays well below the flat transition, so
    /// the whole run renders the globe presentation. The tour covers the two
    /// shading regimes of the sphere surface: the whole planet below zoom 2
    /// (deep tone, layers lit inline per fragment) and the region zooms at
    /// 2 and above (plain palette, layers blend unlit under the deferred
    /// lighting pass), chained by flights whose overview arcs dip through
    /// the low-zoom regime again. The pan spins the planet the way a drag
    /// does.
    static let globe = BenchScenarioScript(
        name: "globe",
        establish: establish,
        warmUp: 8,
        tour: [
            BenchShot(name: "planet",
                      pose: BenchPose(latitude: 25, longitude: 10, zoom: 1.3, bearing: 0, pitch: 0),
                      duration: 5, holdAfter: 3),
            BenchShot(name: "africa",
                      pose: BenchPose(latitude: 5, longitude: 20, zoom: 2.5, bearing: 0, pitch: 0),
                      duration: 5, holdAfter: 2),
            BenchShot(name: "asia",
                      pose: BenchPose(latitude: 35, longitude: 105, zoom: 3.5, bearing: 0, pitch: 0),
                      duration: 6, holdAfter: 2),
            BenchShot(name: "europe",
                      pose: BenchPose(latitude: 48, longitude: 12, zoom: 4.8, bearing: 0, pitch: 0),
                      duration: 6, holdAfter: 2),
            BenchShot(name: "pacific",
                      pose: BenchPose(latitude: -15, longitude: -150, zoom: 2, bearing: 0, pitch: 0),
                      duration: 6, holdAfter: 2),
        ],
        panDuration: 20,
        panStart: globePanStart,
        panPose: { progress in
            // A drag-like spin: a third of the planet passes under the
            // camera while it drifts north, all of it on the sphere.
            let p = min(max(progress, 0), 1)
            return BenchPose(latitude: globePanStart.latitude + 12 * p,
                             longitude: globePanStart.longitude + 120 * p,
                             zoom: globePanStart.zoom,
                             bearing: globePanStart.bearing,
                             pitch: globePanStart.pitch)
        },
        idleSettle: 4,
        idleDuration: 10
    )

    /// Zoom 0 only, and short: the whole run fits in about fifteen seconds,
    /// so an A/B is a pair of quick launches. Every window holds the camera
    /// at zoom 0, the whole planet on screen, where the surface tone is at
    /// its deepest and every tile fragment is lit inline (the deferred
    /// lighting pass needs tone depth 0, which begins at zoom 2). The
    /// flight and the pan only rotate the planet, so the frames differ only
    /// in which hemisphere faces the eye; at 120 Hz even the short windows
    /// hold hundreds of frames.
    static let globe0 = BenchScenarioScript(
        name: "globe0",
        establish: BenchPose(latitude: 10, longitude: 0, zoom: 0, bearing: 0, pitch: 0),
        warmUp: 2,
        tour: [
            BenchShot(name: "spin",
                      pose: BenchPose(latitude: 5, longitude: 120, zoom: 0, bearing: 0, pitch: 0),
                      duration: 3, holdAfter: 1),
        ],
        panDuration: 4,
        panStart: globeZeroPanStart,
        panPose: { progress in
            // A drag-like spin of the whole planet at zoom 0.
            let p = min(max(progress, 0), 1)
            return BenchPose(latitude: globeZeroPanStart.latitude + 8 * p,
                             longitude: globeZeroPanStart.longitude + 120 * p,
                             zoom: 0,
                             bearing: 0,
                             pitch: 0)
        },
        idleSettle: 1,
        idleDuration: 1
    )

    /// Zooms 1 through 6, short: the region zooms where the ground ribbons
    /// (boundaries, road strokes) are actually visible, ending past the
    /// start of the flat transition so the morph frames are on the clock
    /// too. The ladder climbs one continent so the flights are zoom ramps
    /// more than pans; the pan drifts across boundary-dense Europe at the
    /// zoom where every admin line is on screen.
    static let globe16 = BenchScenarioScript(
        name: "globe16",
        establish: BenchPose(latitude: 30, longitude: 15, zoom: 1, bearing: 0, pitch: 0),
        warmUp: 3,
        tour: [
            BenchShot(name: "planet",
                      pose: BenchPose(latitude: 20, longitude: 15, zoom: 1.5, bearing: 0, pitch: 0),
                      duration: 2, holdAfter: 1),
            BenchShot(name: "africa",
                      pose: BenchPose(latitude: 10, longitude: 20, zoom: 3, bearing: 0, pitch: 0),
                      duration: 2, holdAfter: 1),
            BenchShot(name: "europe",
                      pose: BenchPose(latitude: 48, longitude: 12, zoom: 4.5, bearing: 0, pitch: 0),
                      duration: 2, holdAfter: 1),
            BenchShot(name: "alps",
                      pose: BenchPose(latitude: 47, longitude: 10, zoom: 6, bearing: 0, pitch: 0),
                      duration: 2, holdAfter: 1),
        ],
        panDuration: 4,
        panStart: globeMidPanStart,
        panPose: { progress in
            // A drag across boundary-dense central Europe at region zoom.
            let p = min(max(progress, 0), 1)
            return BenchPose(latitude: globeMidPanStart.latitude + 4 * p,
                             longitude: globeMidPanStart.longitude + 14 * p,
                             zoom: globeMidPanStart.zoom,
                             bearing: 0,
                             pitch: 0)
        },
        idleSettle: 1,
        idleDuration: 1
    )

    /// Flat overview zooms, short: past the transition (flat from about
    /// zoom 7), below the street tiers, where the ground bucket carries
    /// everything and the stencil-owned substitutes replace the old slot
    /// clips. The ladder climbs over boundary- and landuse-dense central
    /// Europe, the pan drifts at region scale.
    static let flat9 = BenchScenarioScript(
        name: "flat9",
        establish: BenchPose(latitude: 48, longitude: 11, zoom: 7.5, bearing: 0, pitch: 0),
        warmUp: 3,
        tour: [
            BenchShot(name: "region",
                      pose: BenchPose(latitude: 48.5, longitude: 12.5, zoom: 8, bearing: 0, pitch: 0),
                      duration: 2, holdAfter: 1),
            BenchShot(name: "closer",
                      pose: BenchPose(latitude: 48.14, longitude: 11.58, zoom: 9.5, bearing: 0, pitch: 0),
                      duration: 2, holdAfter: 1),
            BenchShot(name: "back",
                      pose: BenchPose(latitude: 47.5, longitude: 9.5, zoom: 8, bearing: 0, pitch: 0),
                      duration: 2, holdAfter: 1),
        ],
        panDuration: 4,
        panStart: flatMidPanStart,
        panPose: { progress in
            let p = min(max(progress, 0), 1)
            return BenchPose(latitude: flatMidPanStart.latitude + 1.2 * p,
                             longitude: flatMidPanStart.longitude + 3.5 * p,
                             zoom: flatMidPanStart.zoom,
                             bearing: 0,
                             pitch: 0)
        },
        idleSettle: 1,
        idleDuration: 1
    )

    private static let flatMidPanStart = BenchPose(latitude: 47.8, longitude: 8.5,
                                                   zoom: 8.5, bearing: 0, pitch: 0)
    private static let globeMidPanStart = BenchPose(latitude: 46, longitude: 6,
                                                    zoom: 4.2, bearing: 0, pitch: 0)
    private static let fullPanStart = BenchPose(latitude: 40.7484, longitude: -73.9857,
                                                zoom: 15.5, bearing: 30, pitch: 55)
    private static let globeZeroPanStart = BenchPose(latitude: 10, longitude: -60,
                                                     zoom: 0, bearing: 0, pitch: 0)
    private static let globePanStart = BenchPose(latitude: 20, longitude: -60,
                                                 zoom: 2.8, bearing: 0, pitch: 0)
}
