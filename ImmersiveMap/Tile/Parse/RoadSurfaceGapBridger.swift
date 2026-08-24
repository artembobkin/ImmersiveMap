// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Paves the slit between two trimmed pieces of one street.
///
/// The road graph the tiles are built from cuts every street at each node,
/// and where two pieces of one street simply continue into each other the
/// trims leave a narrow slit between the two carriageway polygons: the
/// source ships no polygon for such a joint, because it is not a junction.
/// Left open, the slit shows the ground through the roadway, the kerbs of
/// both trimmed ends draw across the street, and the street's fallback
/// ribbon pokes through at its stated width, which need not match the
/// carriageway: the outer edge of the road grows a notch. The bridger finds
/// each slit and paves it with a quad spanning the two facing trim edges,
/// drawn exactly like the surfaces it joins and clipping the ribbon with
/// them.
///
/// A slit is found by the street's own line: where the line leaves one
/// surface and enters another within a few metres, the piece between the
/// two cut points is a slit, and the outline edges the cut points lie on
/// are the trim edges. The line, and both surfaces, must carry the SAME
/// street identity (the `street` attribute, an id assembled from the whole
/// road network): that requirement is what keeps the bridger off the median
/// of a dual carriageway, whose two opposing one-way roads carry different
/// ids, and off every gap a crossing footpath threads between two unrelated
/// surfaces. All geometry is tile space (y down), the Parse layer's working
/// space.
///
/// There briefly was a second, purely geometric phase that paired facing
/// edges beside junction polygons to cover the wedges no line crosses. It
/// was retired: at a complex junction it paved hulls sticking OUT of the
/// roadway, and a wedge big enough to matter is indistinguishable, by
/// geometry alone, from real ground between two roads. Those wedges are a
/// data problem (the source can ship the polygons of EVERY joint), not a
/// heuristic one.
enum RoadSurfaceGapBridger {
    struct Bridge {
        /// The paving quad, a ring in tile space.
        let ring: [SIMD2<Float>]
        /// Index into the surface-area list of the piece on one side of the
        /// slit: the bridge inherits its style, its attributes and its place
        /// in the draw stack.
        let ownerAreaIndex: Int
    }

    /// The widest slit that is still a joint between two pieces of one
    /// street, in metres on the ground. Connection trims measure a few
    /// metres; a genuine hole in a street is not paved over.
    static let maximumGapMetres: Float = 10

    /// How close (tile units) a piece endpoint must lie to a surface outline
    /// to count as a cut the clipper made there. Cut points are exact
    /// segment intersections, so this only absorbs float error.
    private static let outlineTolerance: Float = 0.5
    /// How close the free ends of two half-pieces must be to be the same
    /// node of the road graph (the way boundary the tiler did not merge).
    private static let sharedEndTolerance: Float = 1.5
    /// The two trim edges must be within 60 degrees of parallel: trims are
    /// near-parallel cuts across one street, however skewed.
    private static let minimumAlignment: Float = 0.5
    /// And of comparable length. A lane gained or lost at the joint changes
    /// the width, but not threefold.
    private static let maximumEdgeLengthRatio: Float = 3

    static func findBridges(surfaceAreas: [TileMvtParser.RoadSurfaceArea],
                            linesByFeatureIndex: [[[SIMD2<Float>]]],
                            featureStyles: [FeatureStyle],
                            featureStreets: [String],
                            featureStructureKinds: [TileMvtParser.RoadStructureKind],
                            featureLayers: [Int],
                            unitsPerMetre: Float) -> [Bridge] {
        guard unitsPerMetre > 0 else { return [] }
        let maximumGap = maximumGapMetres * unitsPerMetre
        // Only the graph-reconstructed surfaces take part: they are the
        // pieces the trims cut apart. A hand-mapped area or a parking lot is
        // not a trimmed piece of anything.
        let candidateIndices = surfaceAreas.indices.filter { surfaceAreas[$0].cutsPaint }
        guard candidateIndices.count >= 2 else { return [] }

        struct EdgeHit {
            let areaIndex: Int
            let edgeIndex: Int
        }
        /// A piece of a line that left a surface and ended in the open: half
        /// of a slit crossing, waiting for the other half from the feature
        /// continuing at the shared node.
        struct HalfPiece {
            let hit: EdgeHit
            let freeEnd: SIMD2<Float>
            let length: Float
            let street: String
        }
        struct EdgePairKey: Hashable {
            let areaA: Int
            let edgeA: Int
            let areaB: Int
            let edgeB: Int
        }

        var halfPieces: [HalfPiece] = []
        var pavedEdgePairs = Set<EdgePairKey>()
        var bridges: [Bridge] = []

        func edge(_ hit: EdgeHit) -> (SIMD2<Float>, SIMD2<Float>) {
            let ring = surfaceAreas[hit.areaIndex].exterior
            return (ring[hit.edgeIndex], ring[(hit.edgeIndex + 1) % ring.count])
        }

        func nearestOutlineEdge(to point: SIMD2<Float>, among areaIndices: [Int]) -> EdgeHit? {
            var best: EdgeHit?
            var bestDistanceSquared = outlineTolerance * outlineTolerance
            for areaIndex in areaIndices {
                let area = surfaceAreas[areaIndex]
                guard point.x >= area.bounds.min.x - outlineTolerance,
                      point.x <= area.bounds.max.x + outlineTolerance,
                      point.y >= area.bounds.min.y - outlineTolerance,
                      point.y <= area.bounds.max.y + outlineTolerance else {
                    continue
                }
                let ring = area.exterior
                for index in 0..<ring.count {
                    let a = ring[index]
                    let b = ring[(index + 1) % ring.count]
                    let ab = b - a
                    let lengthSquared = simd_length_squared(ab)
                    guard lengthSquared > 0 else { continue }
                    let t = simd_clamp(simd_dot(point - a, ab) / lengthSquared, 0, 1)
                    let distanceSquared = simd_distance_squared(point, a + ab * t)
                    if distanceSquared < bestDistanceSquared {
                        bestDistanceSquared = distanceSquared
                        best = EdgeHit(areaIndex: areaIndex, edgeIndex: index)
                    }
                }
            }
            return best
        }

        func signedArea(_ ring: [SIMD2<Float>]) -> Float {
            var area: Float = 0
            for index in 0..<ring.count {
                let next = (index + 1) % ring.count
                area += ring[index].x * ring[next].y - ring[next].x * ring[index].y
            }
            return area * 0.5
        }

        func segmentsCross(_ a: SIMD2<Float>, _ b: SIMD2<Float>,
                           _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
            let r = b - a
            let s = d - c
            let denominator = r.x * s.y - r.y * s.x
            guard abs(denominator) > 1e-9 else { return false }
            let ac = c - a
            let t = (ac.x * s.y - ac.y * s.x) / denominator
            let u = (ac.x * r.y - ac.y * r.x) / denominator
            return t > 0 && t < 1 && u > 0 && u < 1
        }

        func pavingQuad(_ hitA: EdgeHit, _ hitB: EdgeHit) -> [SIMD2<Float>]? {
            let (a0, a1) = edge(hitA)
            let (b0, b1) = edge(hitB)
            let directionA = a1 - a0
            let directionB = b1 - b0
            let lengthA = simd_length(directionA)
            let lengthB = simd_length(directionB)
            guard lengthA > 1, lengthB > 1 else { return nil }
            guard max(lengthA, lengthB) / min(lengthA, lengthB) <= maximumEdgeLengthRatio else { return nil }
            guard abs(simd_dot(directionA / lengthA, directionB / lengthB)) >= minimumAlignment else { return nil }
            guard simd_distance((a0 + a1) * 0.5, (b0 + b1) * 0.5) <= maximumGap * 2 else { return nil }
            // Two rings facing each other run their facing edges in opposite
            // directions, so the quad usually reads a0, a1, b0, b1; the dot
            // decides, and a crossed pair of connecting sides (a heavily
            // skewed joint) is uncrossed by swapping the far edge.
            var ring = simd_dot(directionA, directionB) < 0 ? [a0, a1, b0, b1] : [a0, a1, b1, b0]
            if segmentsCross(ring[1], ring[2], ring[3], ring[0]) {
                ring.swapAt(2, 3)
            }
            guard abs(signedArea(ring)) > 1 else { return nil }
            return ring
        }

        func pave(_ hitA: EdgeHit, _ hitB: EdgeHit, street: String) {
            guard hitA.areaIndex != hitB.areaIndex else { return }
            let areaA = surfaceAreas[hitA.areaIndex]
            let areaB = surfaceAreas[hitB.areaIndex]
            guard street.isEmpty == false,
                  areaA.street == street,
                  areaB.street == street,
                  areaA.structureKind == areaB.structureKind,
                  areaA.layer == areaB.layer else {
                return
            }
            let key = hitA.areaIndex < hitB.areaIndex
                || (hitA.areaIndex == hitB.areaIndex && hitA.edgeIndex <= hitB.edgeIndex)
                ? EdgePairKey(areaA: hitA.areaIndex, edgeA: hitA.edgeIndex,
                              areaB: hitB.areaIndex, edgeB: hitB.edgeIndex)
                : EdgePairKey(areaA: hitB.areaIndex, edgeA: hitB.edgeIndex,
                              areaB: hitA.areaIndex, edgeB: hitA.edgeIndex)
            guard pavedEdgePairs.contains(key) == false else { return }
            guard let ring = pavingQuad(hitA, hitB) else { return }
            pavedEdgePairs.insert(key)
            bridges.append(Bridge(ring: ring, ownerAreaIndex: hitA.areaIndex))
        }

        for featureIndex in linesByFeatureIndex.indices {
            let lines = linesByFeatureIndex[featureIndex]
            guard lines.isEmpty == false else { continue }
            let style = featureStyles[featureIndex]
            guard style.key != 0, style.isShippedRoadPaint == false else { continue }
            let street = featureStreets[featureIndex]
            guard street.isEmpty == false else { continue }
            // Clip against every reconstructed surface of the line's tier,
            // whatever street it belongs to: a junction area along the way
            // covers the line too, and forgetting it would read the span
            // through a small junction as a slit.
            let ownerIndices = candidateIndices.filter {
                surfaceAreas[$0].structureKind == featureStructureKinds[featureIndex]
                    && surfaceAreas[$0].layer == featureLayers[featureIndex]
            }
            guard ownerIndices.isEmpty == false else { continue }
            let owners = ownerIndices.map { surfaceAreas[$0] }
            for polyline in lines {
                for piece in RoadSurfaceClipper.clip(polyline: polyline, outside: owners) {
                    guard let first = piece.first, let last = piece.last else { continue }
                    var length: Float = 0
                    for index in 0..<(piece.count - 1) {
                        length += simd_distance(piece[index], piece[index + 1])
                    }
                    guard length > 0, length <= maximumGap else { continue }
                    let startHit = nearestOutlineEdge(to: first, among: ownerIndices)
                    let endHit = nearestOutlineEdge(to: last, among: ownerIndices)
                    switch (startHit, endHit) {
                    case let (hitA?, hitB?):
                        pave(hitA, hitB, street: street)
                    case let (hit?, nil):
                        halfPieces.append(HalfPiece(hit: hit, freeEnd: last, length: length, street: street))
                    case let (nil, hit?):
                        halfPieces.append(HalfPiece(hit: hit, freeEnd: first, length: length, street: street))
                    case (nil, nil):
                        break
                    }
                }
            }
        }

        // Two pieces of one street meeting in the middle of the slit: the
        // way boundary sits at the node, so each feature's line leaves its
        // own surface and ends there. The halves pair up by that shared end.
        for i in halfPieces.indices {
            for j in halfPieces.indices where j > i {
                let a = halfPieces[i]
                let b = halfPieces[j]
                guard a.street == b.street,
                      a.length + b.length <= maximumGap,
                      simd_distance(a.freeEnd, b.freeEnd) <= sharedEndTolerance else {
                    continue
                }
                pave(a.hit, b.hit, street: a.street)
            }
        }

        return bridges
    }

    /// The street identity used for pairing: the `street` attribute alone.
    /// The name is deliberately NOT a fallback here, unlike stitching: the
    /// two halves of a dual carriageway share a name, and a name match would
    /// let something bridge the median between them.
    static func streetIdentity(_ attributes: [String: VectorTile_Tile.Value]) -> String {
        guard let value = attributes["street"] else { return "" }
        if value.hasStringValue { return value.stringValue }
        if value.hasIntValue { return String(value.intValue) }
        if value.hasUintValue { return String(value.uintValue) }
        if value.hasSintValue { return String(value.sintValue) }
        return ""
    }
}
