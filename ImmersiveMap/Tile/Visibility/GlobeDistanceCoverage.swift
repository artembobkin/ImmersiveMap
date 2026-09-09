// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The globe camera as the coverage sees it: the eye in world units (the
/// camera looks at the world origin, the sphere's front point, and the pan
/// turns the sphere under it) and the globe it looks at, whose pan and
/// radius place every tile's centre in that world.
struct GlobeCoverageCamera {
    var eye: SIMD3<Float>
    var globe: GlobeUniform
    /// The coverage's reach in camera distances, shared with the flat map
    /// (`FlatDistanceCoverage.farRadius`, or the debug panel's value).
    var farRadius: Double = FlatDistanceCoverage.farRadius
}

/// The sphere's coverage rule, the flat one carried over: every visible
/// tile's preferred zoom follows its distance from the eye, measured in
/// space from the eye to the tile's centre on the sphere, in units of the
/// camera's distance to the point it looks at. Within
/// `FlatDistanceCoverage.exactRadius` camera distances a tile is asked for
/// exactly; beyond it the zoom drops one level per `1 / steepness`
/// doublings, with the same thresholds and the same hysteresis memory.
///
/// Two things differ from the plane. The sphere has no backdrop layer, so
/// a tile beyond the reach is not dropped but asked for at the pinned
/// world cover's zoom (z3, always resident, nothing to load): the sphere's
/// stand-in for the backdrop, a handful of tiles once the overlap-free
/// selection has collapsed them. And the preferred zoom never goes below
/// that cover either: a coarser stand-in would be a tile the working set
/// already holds. The overlap-free selection that follows this rule is
/// the preprocessor's own, unchanged: the sphere paints without an
/// ownership stencil, so two targets may not cover the same ground.
///
/// A target zoom at or below the cover's is left alone: the whole world
/// is pinned there and nothing is saved by coarsening.
final class GlobeDistanceCoverage {
    /// The deepest zoom of the pinned world cover (the working set keeps
    /// z0 to z3 resident): the floor of every preferred zoom on the sphere
    /// and what the far field is asked for.
    static let floorZoom = 3

    /// The level memory's mark for a tile that was beyond the reach.
    private static let beyondReach = -1

    private var previousDropsByTile: [VisibleTile: Int] = [:]
    private var previousTargetZoom: Int?

    /// The preferred zoom of every tile, index-aligned with `visibleTiles`,
    /// which the culling emits at one target zoom.
    func preferredZooms(visibleTiles: [VisibleTile], camera: GlobeCoverageCamera) -> [Int] {
        guard let targetZoom = visibleTiles.first?.z else {
            previousDropsByTile.removeAll()
            previousTargetZoom = nil
            return []
        }
        if previousTargetZoom != targetZoom {
            previousDropsByTile.removeAll()
            previousTargetZoom = targetZoom
        }
        let cameraDistance = Double(simd_length(camera.eye))
        guard targetZoom > Self.floorZoom, cameraDistance > 0 else {
            return visibleTiles.map(\.z)
        }

        let inputs = GlobeVisibilityModel.makeInputs(globe: camera.globe, cameraEye: camera.eye)
        let reach = camera.farRadius * cameraDistance
        var drops: [VisibleTile: Int] = [:]
        drops.reserveCapacity(visibleTiles.count)
        var zooms: [Int] = []
        zooms.reserveCapacity(visibleTiles.count)
        for tile in visibleTiles {
            let center = GlobeVisibilityModel.tileBound(tile: tile.tile, inputs: inputs).center
            let distance = Double(simd_length(center - camera.eye))
            let previous = previousDropsByTile[tile]
            if FlatDistanceCoverage.settledBeyondReach(previouslyBeyond: previous.map { $0 == Self.beyondReach },
                                                       distance: distance,
                                                       reach: reach) {
                drops[tile] = Self.beyondReach
                zooms.append(Self.floorZoom)
                continue
            }
            let drop = FlatDistanceCoverage.settledDrop(raw: FlatDistanceCoverage.drop(distance: distance, cameraDistance: cameraDistance),
                                                        previous: previous == Self.beyondReach ? nil : previous,
                                                        distance: distance,
                                                        cameraDistance: cameraDistance)
            drops[tile] = drop
            zooms.append(max(Self.floorZoom, tile.z - drop))
        }
        previousDropsByTile = drops
        return zooms
    }
}
