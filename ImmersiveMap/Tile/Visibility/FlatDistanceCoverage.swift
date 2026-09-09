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
}

/// The flat map's coverage: every visible tile's zoom follows its distance
/// from the eye, and nothing else.
///
/// The distance is measured in space, from the eye to the tile's centre on
/// the ground, in units of the camera's own distance to the point it looks
/// at: that ratio is what perspective scales a tile by, so the rule sees
/// the tilt through the distances alone. Within `exactRadius` camera
/// distances a tile is asked for exactly; beyond it, its zoom drops one
/// level per `1 / steepness` doublings of the distance. Two tiles at the
/// same distance get the same raw level, whichever side of the screen
/// they are on; only the hysteresis can hold two of them a level apart for
/// a while. Targets may overlap (a far parent under a near child): the
/// tile-priority stencil lets the finest painter own each pixel.
///
/// The count is not fixed by the rule. The exact zone is bounded by its
/// radius (four tiles straight down, up to ten at a street tilt), and each
/// level of coarsening beyond it covers a band of distances whose parents
/// are a few times larger, so a tilted view spends a few parents per
/// level. A hard ceiling on the parents trims the farthest when a pose
/// asks for more, so only the horizon suffers, where the backdrop and the
/// haze take over anyway; the exact zone is never trimmed.
///
/// A tile changes level only when its distance has crossed the level's
/// threshold by `hysteresis`, so a boundary sliding with the camera does
/// not flicker the tiles under it. The memory is per target zoom and lasts
/// while the tile stays visible.
///
/// The coverage also stops at `farRadius` camera distances from the eye:
/// beyond it no tile is placed at any zoom, the backdrop and the haze
/// paint the horizon. That is where most of a tilted view's parents were
/// going, a few tiles at a time per level for ground that the fog had all
/// but covered, so the reach is the knob that decides the tile count at a
/// street tilt. It holds with the same hysteresis as the levels.
///
/// A parent that would be the backdrop's zoom or coarser is not placed: the
/// z3 backdrop already paints that ground. Without a backdrop (a target zoom
/// no deeper than z3) it stays, down to z0, so no ground goes unpainted,
/// and the reach does not apply either.
final class FlatDistanceCoverage {
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
    /// places, ties at the cut aside: past it the farthest are left to the
    /// backdrop. The exact tiles come on top, bounded by the exact radius.
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

    /// The level memory's mark for a tile that was beyond the reach.
    private static let beyondReach = -1

    private var previousDropsByTile: [VisibleTile: Int] = [:]
    private var previousTargetZoom: Int?

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

    func targets(visibleTiles: [VisibleTile],
                 camera: FlatCoverageCamera,
                 backdropZoom: Int?) -> [VisibleTile] {
        guard let targetZoom = visibleTiles.first?.z else {
            previousDropsByTile.removeAll()
            previousTargetZoom = nil
            return []
        }
        if previousTargetZoom != targetZoom {
            previousDropsByTile.removeAll()
            previousTargetZoom = targetZoom
        }
        assert(visibleTiles.allSatisfy { $0.z == targetZoom }, "The culling emits one target zoom")
        let lookAtWorld = Self.worldPoint(ofTilePoint: camera.lookAt, zoom: targetZoom, flatRenderState: camera.flatRenderState)
        // In the tiles' own scale: past the source's deepest zoom the tiles
        // keep doubling while the camera's distance does not.
        let cameraDistance = simd_length(camera.eye - lookAtWorld) * pow(2.0, Double(max(0, camera.overzoomLevels)))

        struct Target {
            var nearestMember: Double = .infinity
        }
        var targets: [VisibleTile: Target] = [:]
        var drops: [VisibleTile: Int] = [:]
        drops.reserveCapacity(visibleTiles.count)
        for tile in visibleTiles where tile.z == targetZoom {
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z, loop: tile.loop,
                                                                             flatRenderPan: camera.flatRenderState.pan,
                                                                             renderMapSize: camera.flatRenderState.renderMapSize)
            let center = SIMD3<Double>(Double(originAndSize.x) + Double(originAndSize.z) / 2,
                                       Double(originAndSize.y) + Double(originAndSize.z) / 2,
                                       0)
            let distance = simd_length(center - camera.eye)
            let previous = previousDropsByTile[tile]
            if backdropZoom != nil,
               Self.settledBeyondReach(previouslyBeyond: previous.map { $0 == Self.beyondReach },
                                       distance: distance,
                                       reach: camera.farRadius * cameraDistance) {
                drops[tile] = Self.beyondReach
                continue
            }
            let drop = Self.settledDrop(raw: Self.drop(distance: distance, cameraDistance: cameraDistance),
                                        previous: previous == Self.beyondReach ? nil : previous,
                                        distance: distance,
                                        cameraDistance: cameraDistance)
            drops[tile] = drop
            let zoom = max(0, tile.z - drop)
            if let backdropZoom, zoom <= backdropZoom {
                continue
            }
            guard let target = zoom == tile.z ? tile : (tile.tile.findParentTile(atZoom: zoom).map { VisibleTile(tile: $0, loop: tile.loop) }) else {
                continue
            }
            var entry = targets[target] ?? Target()
            entry.nearestMember = min(entry.nearestMember, distance)
            targets[target] = entry
        }
        previousDropsByTile = drops

        // The ceiling: the farthest parents go, so the horizon alone pays,
        // and the exact zone never does. The cut is a distance, the one
        // the last parent within the ceiling starts at, so two parents as
        // far as each other stay or go together and a mirrored view stays
        // mirrored; a tie can carry the count a little past the ceiling.
        // (Tile centres come from single-precision origins, so a tie is
        // anything within a few of their ulps.) Without a backdrop there
        // is nothing to paint the ground they leave, so a shallow world
        // keeps them all.
        var kept = Array(targets.keys)
        let parents = kept.filter { $0.z < targetZoom }
        if backdropZoom != nil, parents.count > Self.maximumParents {
            let distances = parents.map { targets[$0]!.nearestMember }.sorted()
            let cutoff = distances[Self.maximumParents - 1] * (1 + 1e-5)
            kept = kept.filter { $0.z == targetZoom || targets[$0]!.nearestMember <= cutoff }
        }
        return kept
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

    /// Whether a tile is beyond the reach: past `reach` by the hysteresis
    /// margin when it was within it the frame before, or still past
    /// `reach` less the margin when it was beyond; without a memory, past
    /// `reach` itself.
    static func settledBeyondReach(previouslyBeyond: Bool?, distance: Double, reach: Double) -> Bool {
        switch previouslyBeyond {
        case nil:
            return distance > reach
        case true?:
            return distance >= reach * (1 - hysteresis)
        case false?:
            return distance > reach * (1 + hysteresis)
        }
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
