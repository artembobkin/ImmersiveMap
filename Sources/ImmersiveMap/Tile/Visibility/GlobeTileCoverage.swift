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
    /// One band per rule, nearest first, as on the plane: its zoom, its
    /// last ring and the tiles it placed.
    let bands: [FlatRingBand]
    /// The targets placed by a rule that draws no lines
    /// (`FlatRingRule.drawsLines`). A tile two bands ask for takes the
    /// nearer band's answer, and the cover past the last rule the last
    /// rule's.
    let linelessTargets: Set<VisibleTile>
    let metrics: GlobeCullingMetrics
}

/// What the globe coverage walk reads, taken off the frame once: the eye
/// in world units (the camera looks at the world origin, the sphere's
/// front point, and the pan turns the sphere under it), the globe it looks
/// at, whose pan and radius place every tile's centre in that world, the
/// ring rules, and the target zoom's tile the camera looks at, which the
/// rings are counted from.
struct GlobeCoverageInputs {
    var eye: SIMD3<Float>
    var globe: GlobeUniform
    var rules: FlatRingRules = .default
    var lookAtTile: (x: Int, y: Int)
}

/// The sphere's coverage: the plane's ring rules (`FlatRingRules`) read off
/// the sphere's grid. The walk descends from the root with the frustum and
/// horizon rejects, which stand where the plane has its frustum footprint,
/// and at every tile the rings of its nearest and farthest target tiles
/// from the look-at tile (`GlobeRingMath`) say which rules' bands it
/// meets. A tile is placed when a band it meets is drawn at its zoom, and
/// looked into where a band it meets is drawn finer. Overlapping
/// placements are fine, as on the plane: the sphere draws its sources
/// through the same tile-priority stencil.
///
/// One thing differs from the plane. Beyond the last rule the plane places
/// nothing and leaves the ground to the haze. The sphere has no haze, so
/// ground past the last rule is asked for at the pinned world cover's zoom
/// (`floorZoom`, always resident, nothing to load), and no band goes below
/// that cover either: a coarser stand-in would be a tile the working set
/// already holds.
enum GlobeTileCoverage {
    /// The zoom of the pinned world cover, which the working set keeps
    /// resident: the floor of every placement on the sphere and what the
    /// ground past the last rule is asked for.
    static let floorZoom = TileWorkingSetStore.pinnedWorldCoverMaxZoomLevel

    private static let transitionLowZoomFallbackLimit = 3

    /// One rule as the walk reads it: the rings it owns and the zoom it
    /// draws them at.
    private struct Band {
        let firstRing: Int
        let lastRing: Int
        let zoom: Int
        let drawsLines: Bool
        var tileCount = 0
    }

    private struct Walk {
        let targetZoom: Int
        let frustum: Frustum
        let visibility: GlobeVisibilityInputs
        let lookAtTile: (x: Int, y: Int)
        var bands: [Band]
        var targets: [VisibleTile] = []
        var placed: Set<Tile> = []
        var lineless: Set<VisibleTile> = []
        var metrics = GlobeCullingMetrics.zero
    }

    static func targets(targetZoom: Int, inputs: GlobeCoverageInputs, frustum: Frustum?) -> GlobeCoverageResolution {
        let startTime = CACurrentMediaTime()
        guard targetZoom >= 0, let frustum else {
            return GlobeCoverageResolution(targets: [], bands: [], linelessTargets: [], metrics: .zero)
        }
        var bands: [Band] = []
        for rule in inputs.rules.normalized().rules {
            bands.append(Band(firstRing: bands.last.map { $0.lastRing + 1 } ?? 0,
                              lastRing: rule.distance,
                              zoom: min(targetZoom, max(Self.floorZoom, targetZoom - rule.zoomDrop)),
                              drawsLines: rule.drawsLines))
        }
        var walk = Walk(targetZoom: targetZoom,
                        frustum: frustum,
                        visibility: GlobeVisibilityModel.makeInputs(globe: inputs.globe, cameraEye: inputs.eye),
                        lookAtTile: inputs.lookAtTile,
                        bands: bands)
        visit(Tile(x: 0, y: 0, z: 0), accepted: false, walk: &walk)
        walk.metrics.duration = CACurrentMediaTime() - startTime
        return GlobeCoverageResolution(targets: FlatTileCoverage.sorted(walk.targets),
                                       bands: walk.bands.map {
                                           FlatRingBand(zoom: $0.zoom, distance: $0.lastRing, tileCount: $0.tileCount)
                                       },
                                       linelessTargets: walk.lineless,
                                       metrics: walk.metrics)
    }

    /// `accepted`: the tile lies in a subtree the visibility tests accepted
    /// whole, so they are not asked again below it.
    private static func visit(_ tile: Tile, accepted: Bool, walk: inout Walk) {
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

        // The bands the tile meets: a rule's rings against the rings of the
        // tile's nearest and farthest target tiles. No order of the zooms
        // along the rings is assumed, so any rule list holds.
        let rings = GlobeRingMath.ringRange(of: tile, targetZoom: walk.targetZoom, lookAt: walk.lookAtTile)
        var placesTile = false
        var drawsLines = true
        var finestWanted = Self.floorZoom
        for index in walk.bands.indices {
            let band = walk.bands[index]
            guard band.firstRing <= rings.upperBound, band.lastRing >= rings.lowerBound else { continue }
            finestWanted = max(finestWanted, band.zoom)
            if band.zoom == tile.z, placesTile == false {
                placesTile = true
                drawsLines = band.drawsLines
                if walk.placed.contains(tile) == false {
                    walk.bands[index].tileCount += 1
                }
            }
        }
        // Past the last rule the pinned cover paints the ground.
        if placesTile == false, tile.z == Self.floorZoom, rings.upperBound > (walk.bands.last?.lastRing ?? -1) {
            placesTile = true
            drawsLines = walk.bands.last?.drawsLines ?? true
        }
        if placesTile {
            if walk.placed.contains(tile) == false {
                if drawsLines == false {
                    walk.lineless.insert(VisibleTile(tile: tile))
                }
            }
            place(tile, walk: &walk)
        }
        if tile.z < min(finestWanted, walk.targetZoom) {
            for child in Self.children(of: tile) {
                visit(child, accepted: accepted, walk: &walk)
            }
        }
    }

    private static func place(_ tile: Tile, walk: inout Walk) {
        guard walk.placed.insert(tile).inserted else { return }
        walk.targets.append(VisibleTile(tile: tile))
        walk.metrics.placedTileCount += 1
    }

    /// Through the morph at the coarse zooms every leaf is taken: the
    /// visibility tests do not hold there.
    private static func acceptLeafDescendants(of tile: Tile, walk: inout Walk) {
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

    private static func evaluateVisibility(for tile: Tile,
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

    private static func minimumRejectZoom(targetZoom: Int,
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
