// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore
import simd

struct GlobeCullingMetrics {
    static let zero = GlobeCullingMetrics(duration: 0,
                                          visitedNodeCount: 0,
                                          frustumRejectCount: 0,
                                          horizonRejectCount: 0,
                                          placedTileCount: 0,
                                          acceptedWholeSubtreeCount: 0)

    var duration: TimeInterval
    var visitedNodeCount: Int
    var frustumRejectCount: Int
    var horizonRejectCount: Int
    var placedTileCount: Int
    var acceptedWholeSubtreeCount: Int
}

struct GlobeCoverageResolution {
    let targets: [VisibleTile]
    let metrics: GlobeCullingMetrics
}

/// What the globe coverage walk reads, taken off the frame once: the eye
/// in world units (the camera looks at the world origin, the sphere's
/// front point, and the pan turns the sphere under it), the globe it looks
/// at, whose pan and radius place every tile's centre in that world, and
/// the walk's reach.
struct GlobeCoverageInputs {
    var eye: SIMD3<Float>
    var globe: GlobeUniform
    /// The coverage's reach in camera distances, shared with the flat map
    /// (`FlatDistanceCoverage.farRadius`, or the debug panel's value).
    var farRadius: Double = FlatDistanceCoverage.farRadius
}

/// The sphere's coverage: the same walk as the plane's (`FlatTileCoverage`)
/// over the same distance rule, read off the sphere. The walk descends
/// from the root with the frustum and horizon rejects, and at every tile
/// the distances from the eye to the nearest and farthest points of the
/// tile's bounding sphere say which zooms its ground wants; a tile is
/// placed when its own zoom is among them, and looked into where a finer
/// one is wanted. Overlapping placements are fine: the sphere draws its
/// sources through the same tile-priority stencil as the plane.
///
/// Two things differ from the plane. The sphere has no backdrop layer, so
/// ground beyond the reach is asked for at the pinned world cover's zoom
/// (`floorZoom`, always resident, nothing to load), and no placement goes
/// below that cover either: a coarser stand-in would be a tile the
/// working set already holds. A target zoom at or below the cover's is
/// left alone: the whole world is pinned there and nothing is saved by
/// coarsening, so the walk places the leaves at the target zoom.
final class GlobeTileCoverage {
    /// The deepest zoom of the pinned world cover (the working set keeps
    /// z0 to z3 resident): the floor of every placement on the sphere and
    /// what the far field is asked for.
    static let floorZoom = 3

    private let transitionLowZoomFallbackLimit = 3

    private struct Walk {
        let targetZoom: Int
        let frustum: Frustum
        let visibility: GlobeVisibilityInputs
        let eye: SIMD3<Float>
        let cameraDistance: Double
        let reach: Double
        let usesRule: Bool
        var targets: [VisibleTile] = []
        var placed: Set<Tile> = []
        var metrics = GlobeCullingMetrics.zero
    }

    func targets(targetZoom: Int, inputs: GlobeCoverageInputs, frustum: Frustum?) -> GlobeCoverageResolution {
        let startTime = CACurrentMediaTime()
        guard targetZoom >= 0, let frustum else {
            return GlobeCoverageResolution(targets: [], metrics: .zero)
        }
        let cameraDistance = Double(simd_length(inputs.eye))
        var walk = Walk(targetZoom: targetZoom,
                        frustum: frustum,
                        visibility: GlobeVisibilityModel.makeInputs(globe: inputs.globe, cameraEye: inputs.eye),
                        eye: inputs.eye,
                        cameraDistance: cameraDistance,
                        reach: inputs.farRadius * cameraDistance,
                        usesRule: targetZoom > Self.floorZoom && cameraDistance > 0)
        visit(Tile(x: 0, y: 0, z: 0), accepted: false, walk: &walk)
        walk.metrics.duration = CACurrentMediaTime() - startTime
        return GlobeCoverageResolution(targets: FlatTileCoverage.sorted(walk.targets), metrics: walk.metrics)
    }

    /// `accepted`: the tile lies in a subtree the visibility tests accepted
    /// whole, so they are not asked again below it.
    private func visit(_ tile: Tile, accepted: Bool, walk: inout Walk) {
        walk.metrics.visitedNodeCount += 1
        if walk.visibility.transition > 0, walk.targetZoom <= transitionLowZoomFallbackLimit {
            acceptLeafDescendants(of: tile, walk: &walk)
            return
        }
        var accepted = accepted
        if accepted == false {
            switch evaluateVisibility(for: tile, targetZoom: walk.targetZoom, frustum: walk.frustum, inputs: walk.visibility) {
            case .rejectFrustum:
                walk.metrics.frustumRejectCount += 1
                return
            case .rejectHorizon:
                walk.metrics.horizonRejectCount += 1
                return
            case .acceptWholeSubtree:
                walk.metrics.acceptedWholeSubtreeCount += 1
                accepted = true
            case .descend:
                break
            }
        }
        guard walk.usesRule else {
            if tile.z == walk.targetZoom {
                place(tile, walk: &walk)
                return
            }
            for child in Self.children(of: tile) {
                visit(child, accepted: accepted, walk: &walk)
            }
            return
        }

        let bound = GlobeVisibilityModel.tileBound(tile: tile, inputs: walk.visibility)
        let centerDistance = Double(simd_length(bound.center - walk.eye))
        if tile.z == walk.targetZoom {
            // A leaf: exact by its centre.
            let drop = FlatDistanceCoverage.drop(distance: centerDistance, cameraDistance: walk.cameraDistance)
            if drop == 0 {
                place(tile, walk: &walk)
            } else if let ancestor = tile.findParentTile(atZoom: max(Self.floorZoom, tile.z - drop)) {
                // Wanted coarser: the ancestor at that zoom covers it, placed
                // here if the parents' measure did not.
                place(ancestor, walk: &walk)
            }
            return
        }

        let radius = Double(bound.radius)
        let nearDistance = max(0, centerDistance - radius)
        if nearDistance > walk.reach {
            // The far field: the pinned cover paints it.
            if tile.z == Self.floorZoom {
                place(tile, walk: &walk)
            } else if tile.z < Self.floorZoom {
                for child in Self.children(of: tile) {
                    visit(child, accepted: accepted, walk: &walk)
                }
            }
            return
        }
        let farDistance = centerDistance + radius
        let finest = max(Self.floorZoom,
                         walk.targetZoom - FlatDistanceCoverage.drop(distance: nearDistance,
                                                                     cameraDistance: walk.cameraDistance))
        // Past the reach the ground wants the cover: a tile reaching over
        // the line is wanted down to the floor.
        let coarsest = farDistance > walk.reach
            ? Self.floorZoom
            : max(Self.floorZoom,
                  walk.targetZoom - FlatDistanceCoverage.drop(distance: farDistance,
                                                              cameraDistance: walk.cameraDistance))
        if tile.z >= coarsest, tile.z <= finest {
            place(tile, walk: &walk)
        }
        let finestForDescent = max(Self.floorZoom,
                                   walk.targetZoom - FlatDistanceCoverage.drop(distance: nearDistance,
                                                                               cameraDistance: walk.cameraDistance))
        if tile.z < finestForDescent {
            for child in Self.children(of: tile) {
                visit(child, accepted: accepted, walk: &walk)
            }
        }
    }

    private func place(_ tile: Tile, walk: inout Walk) {
        guard walk.placed.insert(tile).inserted else { return }
        walk.targets.append(VisibleTile(tile: tile))
        walk.metrics.placedTileCount += 1
    }

    /// Through the morph at the coarse zooms every leaf is taken: the
    /// visibility tests do not hold there.
    private func acceptLeafDescendants(of tile: Tile, walk: inout Walk) {
        if tile.z == walk.targetZoom {
            place(tile, walk: &walk)
            return
        }
        for child in Self.children(of: tile) {
            acceptLeafDescendants(of: child, walk: &walk)
        }
    }

    private static func children(of tile: Tile) -> [Tile] {
        let x = tile.x * 2
        let y = tile.y * 2
        let z = tile.z + 1
        return [Tile(x: x, y: y, z: z), Tile(x: x + 1, y: y, z: z),
                Tile(x: x, y: y + 1, z: z), Tile(x: x + 1, y: y + 1, z: z)]
    }

    private func evaluateVisibility(for tile: Tile,
                                    targetZoom: Int,
                                    frustum: Frustum,
                                    inputs: GlobeVisibilityInputs) -> GlobeNodeVisibilityEvaluation {

        let shouldRejectAtZoom = tile.z >= minimumRejectZoom(targetZoom: targetZoom,
                                                             transition: inputs.transition)
        let needsWholeSubtreeEvaluation = tile.z < targetZoom

        guard shouldRejectAtZoom || needsWholeSubtreeEvaluation else {
            return .descend
        }

        let bound = GlobeVisibilityModel.tileBound(tile: tile, inputs: inputs)

        if shouldRejectAtZoom,
           frustum.isSphereVisible(center: bound.center, radius: bound.radius) == false {
            return .rejectFrustum
        }

        if shouldRejectAtZoom,
           GlobeVisibilityModel.tileMayPassHorizon(bound: bound, inputs: inputs) == false {
            return .rejectHorizon
        }

        if needsWholeSubtreeEvaluation,
           frustum.containsSphere(center: bound.center, radius: bound.radius),
           GlobeVisibilityModel.tilePassesHorizonEntirely(bound: bound, inputs: inputs) {
            return .acceptWholeSubtree
        }

        return .descend
    }

    private func minimumRejectZoom(targetZoom: Int,
                                   transition: Float) -> Int {
        min(targetZoom, transition > 0 ? 4 : 3)
    }
}

enum GlobeNodeVisibilityEvaluation {
    case rejectFrustum
    case rejectHorizon
    case descend
    case acceptWholeSubtree
}
