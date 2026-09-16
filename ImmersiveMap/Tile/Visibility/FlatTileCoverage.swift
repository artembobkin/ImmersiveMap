// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The flat map's coverage in one walk of the tile tree, from the root of
/// each world copy down, deciding at every tile whether to place it and
/// whether to look inside it.
///
/// A tile is placed when some of its ground wants exactly its zoom. The
/// distance rule (`FlatDistanceCoverage`) turns the distances from the eye
/// to the tile's nearest and farthest points into the finest and the
/// coarsest zoom wanted anywhere in it, and since the wanted zoom only
/// gets coarser with distance, the ground in between wants every zoom
/// between the two. The walk looks inside a tile only where the finest
/// wanted zoom is finer than the tile's own. So a far parent is placed
/// whole, under the nearer children placed on top of it, and the tiles'
/// overlap is resolved per pixel by the tile-priority stencil: about
/// eighteen tiles at a street tilt, with no leaf enumerated that a parent
/// covers.
///
/// At the target zoom a tile is exact by its centre's distance, with the
/// level memory: it changes between exact and not only once its distance
/// has crossed the threshold by the hysteresis margin. The walk looks
/// into a tile a margin (`descentMargin`) earlier than the rule asks, so a
/// leaf the memory still holds exact is reached; and a leaf the memory
/// holds a level coarser than the rule asks places its own parent at the
/// held level, so the ground under it stays covered without widening any
/// parent's band.
///
/// Beyond `farRadius` camera distances nothing is placed: the backdrop
/// paints the horizon, and the walk does not look there. Parents at the
/// backdrop's zoom or coarser are not placed either, since the backdrop
/// already paints that ground; without a backdrop (a target zoom no
/// deeper than the backdrop's) the reach does not apply and the parents
/// go down to z0, so no ground goes unpainted. The parents ceiling
/// (`FlatDistanceCoverage.maximumParents`) trims the farthest when a
/// pose asks for more.
final class FlatTileCoverage {
    private static let loops: [Int8] = [-1, 0, 1]

    /// How much nearer than the rule asks the walk looks into a tile: a
    /// leaf the memory holds exact is at most this far past the exact
    /// threshold, and the walk has to reach it to read the memory.
    static let descentMargin: Double = 1 + FlatDistanceCoverage.hysteresis

    private var leafDrops: [VisibleTile: Int] = [:]
    private var nextLeafDrops: [VisibleTile: Int] = [:]
    private var previousTargetZoom: Int?
    /// How many tiles the last walk looked at, for the diagnostics.
    private(set) var visitedNodeCount = 0

    private struct Walk {
        let targetZoom: Int
        let inputs: FlatCoverageInputs
        let polygon: CoveragePolygon
        let cameraDistance: Double
        /// The reach in world units, nil without a backdrop.
        let reach: Double?
        /// Every placed tile with the distance to its nearest point.
        var placed: [VisibleTile: Double] = [:]
        var visited = 0
    }

    func targets(targetZoom: Int, inputs: FlatCoverageInputs, polygon: CoveragePolygon) -> [VisibleTile] {
        guard targetZoom >= 0 else {
            leafDrops.removeAll()
            return []
        }
        if previousTargetZoom != targetZoom {
            leafDrops.removeAll()
            previousTargetZoom = targetZoom
        }
        nextLeafDrops.removeAll(keepingCapacity: true)
        let lookAtWorld = FlatDistanceCoverage.worldPoint(ofTilePoint: inputs.lookAt, zoom: targetZoom,
                                                          flatRenderState: inputs.flatRenderState)
        // In the tiles' own scale: past the source's deepest zoom the tiles
        // keep doubling while the camera's distance does not.
        let cameraDistance = simd_length(inputs.eye - lookAtWorld) * pow(2.0, Double(max(0, inputs.overzoomLevels)))
        var walk = Walk(targetZoom: targetZoom,
                        inputs: inputs,
                        polygon: polygon,
                        cameraDistance: cameraDistance,
                        reach: inputs.backdropZoom == nil ? nil : inputs.farRadius * cameraDistance)
        for loop in Self.loops {
            visit(VisibleTile(x: 0, y: 0, z: 0, loop: loop), walk: &walk)
        }
        leafDrops = nextLeafDrops
        visitedNodeCount = walk.visited

        // The ceiling: the farthest parents go, so the horizon alone pays,
        // and the exact zone never does. The cut is a distance, the one
        // the last parent within the ceiling starts at, so two parents as
        // far as each other stay or go together and a mirrored view stays
        // mirrored; a tie can carry the count a little past the ceiling.
        // Without a backdrop there is nothing to paint the ground they
        // leave, so a shallow world keeps them all.
        var kept = Array(walk.placed.keys)
        let parents = kept.filter { $0.z < targetZoom }
        if inputs.backdropZoom != nil, parents.count > FlatDistanceCoverage.maximumParents {
            let distances = parents.map { walk.placed[$0]! }.sorted()
            let cutoff = distances[FlatDistanceCoverage.maximumParents - 1] * (1 + 1e-5)
            kept = kept.filter { $0.z == targetZoom || walk.placed[$0]! <= cutoff }
        }
        return Self.sorted(kept)
    }

    /// The tiles at `zoom` the polygon meets, every world copy, in a
    /// deterministic order: the horizon backdrop's enumeration.
    static func tiles(atZoom zoom: Int, polygon: CoveragePolygon, flatRenderState: FlatRenderState) -> [VisibleTile] {
        guard zoom >= 0 else { return [] }
        var tiles: [VisibleTile] = []
        func visit(_ node: VisibleTile) {
            guard Self.square(of: node, flatRenderState: flatRenderState, meets: polygon) != nil else { return }
            if node.z == zoom {
                tiles.append(node)
                return
            }
            for child in Self.children(of: node) {
                visit(child)
            }
        }
        for loop in loops {
            visit(VisibleTile(x: 0, y: 0, z: 0, loop: loop))
        }
        return tiles.sorted { lhs, rhs in
            if lhs.loop != rhs.loop { return lhs.loop < rhs.loop }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
    }

    private func visit(_ node: VisibleTile, walk: inout Walk) {
        walk.visited += 1
        guard let square = Self.square(of: node, flatRenderState: walk.inputs.flatRenderState, meets: walk.polygon) else {
            return
        }
        let eye = walk.inputs.eye
        if node.z == walk.targetZoom {
            // A leaf: exact by its centre, with the memory.
            let center = SIMD3<Double>((square.minX + square.maxX) / 2, (square.minY + square.maxY) / 2, 0)
            let distance = simd_length(center - eye)
            let drop = FlatDistanceCoverage.settledDrop(
                raw: FlatDistanceCoverage.drop(distance: distance, cameraDistance: walk.cameraDistance),
                previous: leafDrops[node],
                distance: distance,
                cameraDistance: walk.cameraDistance)
            nextLeafDrops[node] = drop
            if drop == 0 {
                walk.placed[node] = distance
            } else if let ancestor = node.tile.findParentTile(atZoom: max(0, node.z - drop)),
                      walk.inputs.backdropZoom.map({ ancestor.z > $0 }) ?? true {
                // Held a level coarser than the rule asks: the parent at the
                // held level covers it, placed here if the rule did not.
                let target = VisibleTile(tile: ancestor, loop: node.loop)
                walk.placed[target] = min(walk.placed[target] ?? .infinity, distance)
            }
            return
        }

        // Only the ground in view says which zooms the tile is wanted at:
        // the square clipped to the footprint, its nearest and farthest
        // points from the eye.
        guard let (nearDistance, _) = Self.distances(from: eye, toSquare: square, clippedTo: walk.polygon) else {
            return
        }
        if let reach = walk.reach, nearDistance > reach {
            // Wholly beyond the reach: the backdrop's.
            return
        }
        // The rule is read at the leaves' centres, and no leaf centre lies
        // nearer than half a leaf to a tile's edge: the tile is placed by
        // the ground its leaf centres cover, the square inset by that much,
        // so a band that only grazes the edge does not place it. The inset
        // part may lie outside the view while the tile still holds leaves
        // in it, which is why the descent is decided on the whole square.
        let inset = walk.inputs.flatRenderState.renderMapSize / Double(1 << walk.targetZoom) / 2
        let sampled = Square(minX: square.minX + inset, minY: square.minY + inset,
                             maxX: square.maxX - inset, maxY: square.maxY - inset)
        if let (nearSampled, farSampled) = Self.distances(from: eye, toSquare: sampled, clippedTo: walk.polygon) {
            var farDistance = farSampled
            if let reach = walk.reach {
                // Ground beyond the reach wants nothing: only what is within
                // it says which zooms the tile is wanted at.
                farDistance = min(farDistance, reach)
            }
            let finest = max(0, walk.targetZoom - FlatDistanceCoverage.drop(distance: nearSampled,
                                                                            cameraDistance: walk.cameraDistance))
            let coarsest = max(0, walk.targetZoom - FlatDistanceCoverage.drop(distance: farDistance,
                                                                              cameraDistance: walk.cameraDistance))
            if nearSampled <= (walk.reach ?? .infinity), node.z >= coarsest, node.z <= finest,
               walk.inputs.backdropZoom.map({ node.z > $0 }) ?? true {
                // Keyed by where the tile's band starts inside it: the nearest
                // ground that wants this zoom, which is what the ceiling ranks
                // the parents by.
                let bandStart = FlatDistanceCoverage.threshold(ofLevel: walk.targetZoom - node.z, cameraDistance: walk.cameraDistance)
                walk.placed[node] = min(walk.placed[node] ?? .infinity, max(nearSampled, bandStart))
            }
        }
        // Looked into a margin early, so a leaf the memory holds exact is
        // reached and read.
        let finestForDescent = max(0, walk.targetZoom - FlatDistanceCoverage.drop(distance: nearDistance / Self.descentMargin,
                                                                                  cameraDistance: walk.cameraDistance))
        if node.z < finestForDescent {
            for child in Self.children(of: node) {
                visit(child, walk: &walk)
            }
        }
    }

    private struct Square {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
    }

    /// The distances from the eye to the nearest and the farthest point of
    /// the square's part inside the polygon, nil when nothing of it is.
    /// The part is the square clipped against the polygon's edges, a convex
    /// polygon of a few vertices: the farthest point is one of them, the
    /// nearest lies on an edge or under the eye.
    private static func distances(from eye: SIMD3<Double>, toSquare square: Square, clippedTo polygon: CoveragePolygon) -> (Double, Double)? {
        var vertices: [SIMD2<Double>] = [SIMD2<Double>(square.minX, square.minY), SIMD2<Double>(square.maxX, square.minY),
                                         SIMD2<Double>(square.maxX, square.maxY), SIMD2<Double>(square.minX, square.maxY)]
        let count = polygon.vertices.count
        let orientation = polygon.signedArea >= 0 ? 1.0 : -1.0
        for index in 0 ..< count {
            let start = SIMD2<Double>(polygon.vertices[index])
            let end = SIMD2<Double>(polygon.vertices[(index + 1) % count])
            let edge = end - start
            func inside(_ point: SIMD2<Double>) -> Double {
                // Positive on the polygon's side of the edge, the
                // orientation folded in.
                orientation * (edge.x * (point.y - start.y) - edge.y * (point.x - start.x))
            }
            var clipped: [SIMD2<Double>] = []
            clipped.reserveCapacity(vertices.count + 2)
            for vertexIndex in vertices.indices {
                let current = vertices[vertexIndex]
                let previous = vertices[(vertexIndex + vertices.count - 1) % vertices.count]
                let currentInside = inside(current) >= 0
                let previousInside = inside(previous) >= 0
                if currentInside {
                    if previousInside == false {
                        clipped.append(intersection(previous, current, start, end))
                    }
                    clipped.append(current)
                } else if previousInside {
                    clipped.append(intersection(previous, current, start, end))
                }
            }
            vertices = clipped
            if vertices.isEmpty {
                return nil
            }
        }
        let eyeGround = SIMD2<Double>(eye.x, eye.y)
        var nearestPlanar = Double.infinity
        var farthestPlanar = 0.0
        var eyeInside = true
        for index in vertices.indices {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]
            farthestPlanar = max(farthestPlanar, simd_length(start - eyeGround))
            let edge = end - start
            let lengthSquared = simd_length_squared(edge)
            let t = lengthSquared > 0 ? min(max(simd_dot(eyeGround - start, edge) / lengthSquared, 0), 1) : 0
            nearestPlanar = min(nearestPlanar, simd_length(start + edge * t - eyeGround))
            if orientation * (edge.x * (eyeGround.y - start.y) - edge.y * (eyeGround.x - start.x)) < 0 {
                eyeInside = false
            }
        }
        if eyeInside {
            nearestPlanar = 0
        }
        let height = eye.z * eye.z
        return ((nearestPlanar * nearestPlanar + height).squareRoot(), (farthestPlanar * farthestPlanar + height).squareRoot())
    }

    /// Where the segment from `a` to `b` crosses the line through `c` and `d`.
    private static func intersection(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> SIMD2<Double> {
        let ab = b - a
        let cd = d - c
        let denominator = ab.x * cd.y - ab.y * cd.x
        guard abs(denominator) > 1e-18 else { return a }
        let t = ((c.x - a.x) * cd.y - (c.y - a.y) * cd.x) / denominator
        return a + ab * t
    }

    /// The tile's square in world units, nil when the polygon misses it.
    private static func square(of node: VisibleTile, flatRenderState: FlatRenderState, meets polygon: CoveragePolygon) -> Square? {
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: node.x, y: node.y, z: node.z, loop: node.loop,
                                                                  flatRenderPan: flatRenderState.pan,
                                                                  renderMapSize: flatRenderState.renderMapSize)
        let square = Square(minX: Double(origin.x),
                            minY: Double(origin.y),
                            maxX: Double(origin.x) + Double(origin.z),
                            maxY: Double(origin.y) + Double(origin.z))
        guard polygon.intersects(minX: square.minX, minY: square.minY, maxX: square.maxX, maxY: square.maxY) else {
            return nil
        }
        return square
    }

    private static func children(of node: VisibleTile) -> [VisibleTile] {
        let x = node.x * 2
        let y = node.y * 2
        let z = node.z + 1
        return [VisibleTile(x: x, y: y, z: z, loop: node.loop),
                VisibleTile(x: x + 1, y: y, z: z, loop: node.loop),
                VisibleTile(x: x, y: y + 1, z: z, loop: node.loop),
                VisibleTile(x: x + 1, y: y + 1, z: z, loop: node.loop)]
    }

    /// Renderer-stable order: finest first, then by world copy and position.
    static func sorted(_ targets: [VisibleTile]) -> [VisibleTile] {
        targets.sorted { lhs, rhs in
            if lhs.z != rhs.z { return lhs.z > rhs.z }
            if lhs.loop != rhs.loop { return lhs.loop < rhs.loop }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
    }
}
