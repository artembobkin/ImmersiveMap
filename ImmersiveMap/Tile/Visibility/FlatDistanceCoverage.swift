// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The flat camera as the coverage sees it: the eye in world units (the
/// engine's camera looks at the world origin, the flat pan moves the world
/// under it, so this is the frame's eye as it is), the flat render state
/// that places tiles in that world, and the two ground points in tile
/// units of the target zoom: the eye's, which the building coverage
/// measures its field from, and the look-at point, which the coverage
/// projects into the world for the camera's own distance.
struct FlatCoverageCamera {
    var eye: SIMD3<Double>
    var flatRenderState: FlatRenderState
    var eyeGround: SIMD2<Double>
    var lookAt: SIMD2<Double>
    /// How many levels the camera's zoom sits above the target zoom, which
    /// the tile source caps (`maximumZoomLevel`): each level doubles the
    /// tiles' world size while the camera's distance stays, so the
    /// coverage measures distances in the tiles' own scale.
    var overzoomLevels: Int = 0
    /// The zoom of the horizon backdrop drawn under the coverage, nil when
    /// none is: decided once, by the frame, for the coverage and the
    /// placement alike.
    var backdropZoom: Int? = TileCulling.flatBackdropZoomLevel
    /// The coverage's reach in camera distances (`FlatDistanceCoverage.farRadius`
    /// unless the debug panel moves it): ground farther than this is left to
    /// the backdrop.
    var farRadius: Double = FlatDistanceCoverage.farRadius

    /// The frame's flat camera as the coverage reads it. The engine's camera
    /// looks at the world origin (the pan moves the world under it), so the
    /// eye is taken as it is; its ground point is its x and y over the
    /// target zoom's tile size, away from the look-at point in tile units,
    /// with world y growing north while tile y grows south.
    static func make(eye: SIMD3<Float>,
                     flatRenderState: FlatRenderState,
                     center: Center,
                     targetZoom: Int,
                     cameraZoom: Double,
                     backdropZoom: Int?,
                     farRadius: Double) -> FlatCoverageCamera {
        let lookAt = SIMD2<Double>(center.tileX, center.tileY)
        return FlatCoverageCamera(eye: SIMD3<Double>(Double(eye.x), Double(eye.y), Double(eye.z)),
                                  flatRenderState: flatRenderState,
                                  eyeGround: eyeGround(eye: eye, flatRenderState: flatRenderState, lookAt: lookAt, targetZoom: targetZoom),
                                  lookAt: lookAt,
                                  overzoomLevels: max(0, Int(cameraZoom) - targetZoom),
                                  backdropZoom: backdropZoom,
                                  farRadius: farRadius)
    }

    /// The eye's ground point in tile units of `targetZoom`.
    static func eyeGround(eye: SIMD3<Float>, flatRenderState: FlatRenderState, lookAt: SIMD2<Double>, targetZoom: Int) -> SIMD2<Double> {
        let tileUnits = flatRenderState.renderMapSize / Double(1 << max(0, targetZoom))
        return lookAt + SIMD2<Double>(Double(eye.x), -Double(eye.y)) / tileUnits
    }
}

/// The distance rule the coverage walks the tile tree with: every point
/// of the ground wants a zoom by its distance from the eye, and nothing
/// else.
///
/// The distance is measured in space, from the eye to the ground, in units
/// of the camera's own distance to the point it looks at: that ratio is
/// what perspective scales a tile by, so the rule sees the tilt through
/// the distances alone. Within `exactRadius` camera distances the ground
/// wants the target zoom; beyond it, one level coarser per `1 / steepness`
/// doublings of the distance. The wanted zoom only gets coarser with the
/// distance, which is what lets the walk (`FlatTileCoverage`,
/// `GlobeTileCoverage`) read a whole tile's range of wanted zooms off its
/// nearest and farthest points.
///
/// The rule also stops at `farRadius` camera distances from the eye:
/// beyond it no tile is placed at any zoom, the backdrop and the haze
/// paint the horizon on the plane, the pinned world cover on the sphere.
///
/// A tile at the target zoom changes between exact and not only when its
/// distance has crossed the threshold by `hysteresis`, so a boundary
/// sliding with the camera does not flicker the tiles under it
/// (`settledDrop`, with the walk's per-leaf memory).
enum FlatDistanceCoverage {
    /// The radius of the exact zone in camera distances: everything nearer
    /// than this many times the camera's distance to its look-at point is
    /// asked for at the target zoom. 2.5 covers the whole view straight down
    /// and up to a 30 degree tilt at any fraction of a zoom level, so a
    /// gently tilted map is exact wall to wall.
    static let exactRadius: Double = 2.5
    /// Levels dropped per doubling of the distance beyond the exact zone.
    /// 1 is honest perspective; 2 coarsens the far field twice as fast,
    /// which keeps a street tilt near the ceiling instead of far above it.
    static let steepness: Double = 2.0
    /// The most parents (targets coarser than the target zoom) a frame
    /// places on the plane, ties at the cut aside: past it the farthest are
    /// left to the backdrop. The exact tiles come on top, bounded by the
    /// exact radius. A guard, since the walk bounds the count by the rule
    /// itself.
    static let maximumParents = 14
    /// How far past a level's threshold a tile's distance must go before
    /// the tile changes level, as a fraction of the threshold.
    static let hysteresis: Double = 0.1
    /// The reach in camera distances: ground farther than this many times
    /// the camera's distance to its look-at point is left to the backdrop.
    /// 10 keeps a street tilt at about ten parents instead of the ceiling's
    /// fourteen and cuts nothing at a gentle tilt, whose view ends nearer.
    static let farRadius: Double = 10
    /// The debug panel's range for the reach.
    static let farRadiusRange: ClosedRange<Double> = 3 ... 40

    static func clampFarRadius(_ farRadius: Double) -> Double {
        guard farRadius.isFinite else { return Self.farRadius }
        return min(max(farRadius, farRadiusRange.lowerBound), farRadiusRange.upperBound)
    }

    /// The number of levels a tile at `distance` drops, before hysteresis.
    static func drop(distance: Double, cameraDistance: Double) -> Int {
        let exactDistance = exactRadius * max(cameraDistance, 1e-9)
        guard distance > exactDistance else {
            return 0
        }
        return Int(ceil(steepness * log2(distance / exactDistance) - 1e-9))
    }

    /// The distance at which the drop reaches `level` (1 or more).
    static func threshold(ofLevel level: Int, cameraDistance: Double) -> Double {
        exactRadius * max(cameraDistance, 1e-9) * pow(2.0, Double(level - 1) / steepness)
    }

    /// The world position of a point in tile units of `zoom`: tile y grows
    /// south while world y grows north, so the fraction flips.
    static func worldPoint(ofTilePoint point: SIMD2<Double>, zoom: Int, flatRenderState: FlatRenderState) -> SIMD3<Double> {
        let x = Int(floor(point.x))
        let y = Int(floor(point.y))
        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: x, y: y, z: zoom, loop: 0,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let size = Double(originAndSize.z)
        return SIMD3<Double>(Double(originAndSize.x) + (point.x - Double(x)) * size,
                             Double(originAndSize.y) + (1 - (point.y - Double(y))) * size,
                             0)
    }

    /// The level a tile settles at: the raw level, unless its distance has
    /// not yet crossed the threshold between its previous level and the
    /// raw one by the hysteresis margin.
    static func settledDrop(raw: Int, previous: Int?, distance: Double, cameraDistance: Double) -> Int {
        guard let previous, previous != raw else {
            return raw
        }
        var settled = previous
        if raw > previous {
            for level in (previous + 1) ... raw {
                guard distance > threshold(ofLevel: level, cameraDistance: cameraDistance) * (1 + hysteresis) else {
                    break
                }
                settled = level
            }
        } else {
            for level in stride(from: previous - 1, through: raw, by: -1) {
                guard distance < threshold(ofLevel: level + 1, cameraDistance: cameraDistance) * (1 - hysteresis) else {
                    break
                }
                settled = level
            }
        }
        return settled
    }
}
