// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The knobs of the sphere's distance rule (`FlatDistanceCoverage`, read
/// by `GlobeTileCoverage`). The plane's coverage is the depth rules
/// (`FlatDepthRuleCoverage`) and reads none of this.
struct CoverageRule: Hashable {
    /// The exact zone's radius, in camera distances.
    var exactRadius: Double = FlatDistanceCoverage.exactRadius
    /// Levels dropped per doubling of the distance beyond the exact zone.
    var steepness: Double = FlatDistanceCoverage.steepness
    /// The reach, in camera distances.
    var farRadius: Double = FlatDistanceCoverage.farRadius

    static let `default` = CoverageRule()
}

/// The distance rule the sphere's coverage walks the tile tree with: every
/// point of the ground wants a zoom by its distance from the eye, and
/// nothing else.
///
/// The distance is measured in space, from the eye to the ground, in units
/// of the camera's own distance to the point it looks at: that ratio is
/// what perspective scales a tile by, so the rule sees the tilt through
/// the distances alone. Within `exactRadius` camera distances the ground
/// wants the target zoom; beyond it, one level coarser per `1 / steepness`
/// doublings of the distance. The wanted zoom only gets coarser with the
/// distance, which is what lets the walk (`GlobeTileCoverage`) read a
/// whole tile's range of wanted zooms off its nearest and farthest points.
///
/// The rule also stops at `farRadius` camera distances from the eye:
/// beyond it no tile is placed at any zoom, the pinned world cover paints
/// the sphere's far side.
enum FlatDistanceCoverage {
    /// The radius of the exact zone in camera distances: everything nearer
    /// than this many times the camera's distance to its look-at point is
    /// asked for at the target zoom.
    static let exactRadius: Double = 2.5
    /// Levels dropped per doubling of the distance beyond the exact zone.
    static let steepness: Double = 2.0
    /// The reach in camera distances: ground farther than this many times
    /// the camera's distance to its look-at point is left to the cover.
    static let farRadius: Double = 10

    /// The number of levels a tile at `distance` drops.
    static func drop(distance: Double, cameraDistance: Double, rule: CoverageRule = .default) -> Int {
        let exactDistance = rule.exactRadius * max(cameraDistance, 1e-9)
        guard distance > exactDistance else {
            return 0
        }
        return Int(ceil(rule.steepness * log2(distance / exactDistance) - 1e-9))
    }

    /// The distance at which the drop reaches `level` (1 or more).
    static func threshold(ofLevel level: Int, cameraDistance: Double, rule: CoverageRule = .default) -> Double {
        rule.exactRadius * max(cameraDistance, 1e-9) * pow(2.0, Double(level - 1) / rule.steepness)
    }
}
