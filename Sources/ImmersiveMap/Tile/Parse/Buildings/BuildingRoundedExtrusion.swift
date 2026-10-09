// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Earcut
import Foundation
import simd

/// A building with rounded edges (`ExtrusionStyle.edgeRadius`): the box
/// with a narrow bevel along every vertical corner and around the rim of
/// its roof, the way the commercial engines round theirs. On the ground it
/// stands on its footprint as it is: the corners are sharp there. Not an arc of
/// many segments: one bevel face per edge, whose vertices take the normals
/// of the two faces it joins. The shading reads the interpolated normal,
/// so the tone runs from one face into the next across the bevel and the
/// eye reads a round edge. The silhouette is cut by the bevel too.
///
/// Per footprint edge that stands as a wall, the wall itself (its top
/// lowered by the radius, its ends drawn back from the corners from a
/// radius over the ground up, and reaching the corners on the ground),
/// then the band from its top up to the roof's rim. Per rounded corner,
/// the vertical bevel between the two walls, the triangle that closes it
/// under the roof, and the one that takes it down to the sharp corner of
/// the footprint. The roof is the footprint drawn in by the radius, and
/// triangulated from the footprint as it was, so the inset never breaks
/// the triangulation however the footprint bends.
///
/// The radius shrinks to what the building can take: a quarter of its
/// narrow side, read off its area and perimeter, and under half its
/// height. A corner draws its walls back at most a third of either edge.
/// Where the footprint was clipped at the tile's edge nothing is rounded,
/// so the building meets its continuation in the next tile.
extension BuildingExtrusionMeshBuilder {
    /// The smallest radius worth drawing, in tile units: under it the
    /// bevel is lost to the vertex quantization (`ExtrudedVertexIn`).
    static let minimumEdgeRadius: Float = 0.5

    /// One footprint ring as the rounded build reads it: its points in
    /// wall order, and per point what the corner does.
    private struct RoundedRing {
        let points: [SIMD2<Float>]
        /// The unit direction of the edge from a point to the next, zero
        /// for an edge of no length. One value per edge, read by the wall
        /// and by both corners it ends in, so they meet exactly.
        let directions: [SIMD2<Float>]
        /// Whether the edge from a point to the next stands as a wall.
        let isWall: [Bool]
        /// How far the walls draw back from a point along their edges,
        /// zero where the corner stays sharp.
        let drawBack: [Float]
        /// Where the roof's rim is above a point: the point drawn in.
        let roofPoint: [SIMD2<Float>]
    }

    /// The rounded mesh, nil when the radius comes to nothing for this
    /// building or the footprint cannot be triangulated: the caller then
    /// builds the sharp box.
    static func buildRounded(clippedExterior: [SIMD2<Float>],
                             clippedInteriors: [[SIMD2<Float>]],
                             baseHeight: Float,
                             topHeight: Float,
                             edgeRadius: Float,
                             tileExtent: Float) -> ParsedExtrudedMesh? {
        // Exterior clockwise, holes counter-clockwise, as the sharp build
        // winds them: every wall's left normal faces out of the material.
        let exterior = ensureWinding(sanitizeRing(clippedExterior), clockwise: true)
        guard exterior.count >= 3 else { return nil }
        let interiors = clippedInteriors
            .map { ensureWinding(sanitizeRing($0), clockwise: false) }
            .filter { $0.count >= 3 }

        let perimeter = zip(exterior, exterior.dropFirst() + [exterior[0]]).reduce(Float(0)) {
            $0 + simd_distance($1.0, $1.1)
        }
        let area = abs(ringArea(exterior))
        guard perimeter > 0 else { return nil }
        // Area over perimeter is half the narrow side of a long block.
        let radius = min(edgeRadius, (topHeight - baseHeight) * 0.45, area / perimeter * 0.5)
        guard radius >= minimumEdgeRadius else { return nil }

        // The roof from the footprint as it is.
        var coordinates: [Double] = []
        var holeIndices: [Int] = []
        for point in exterior {
            coordinates.append(Double(point.x))
            coordinates.append(Double(point.y))
        }
        for interior in interiors {
            holeIndices.append(coordinates.count / 2)
            for point in interior {
                coordinates.append(Double(point.x))
                coordinates.append(Double(point.y))
            }
        }
        let roofIndices = Earcut.tessellate(data: coordinates, holeIndices: holeIndices)
        guard roofIndices.count >= 3 else { return nil }

        let rings = ([exterior] + interiors).map { roundedRing($0, radius: radius, tileExtent: tileExtent) }

        var builder = MeshBuilder()
        let up = SIMD3<Float>(0, 0, 1)
        let wallTop = topHeight - radius
        // Where the corners are rounded from: under it the walls widen to
        // the footprint's corners, so the building stands on its footprint.
        let bevelBottom = baseHeight + radius

        // The roof, drawn in.
        let roofPoints = rings.flatMap(\.roofPoint)
        let roofStart = UInt32(builder.vertices.count)
        for point in roofPoints {
            builder.vertices.append(ParsedExtrudedVertex(position: SIMD3<Float>(point.x, point.y, topHeight),
                                                         normal: up,
                                                         surfaceID: 0))
        }
        for triangle in stride(from: 0, to: roofIndices.count - 2, by: 3) {
            builder.appendTriangle(roofStart + roofIndices[triangle],
                                   roofStart + roofIndices[triangle + 1],
                                   roofStart + roofIndices[triangle + 2],
                                   outward: up)
        }

        for ring in rings {
            let count = ring.points.count
            for index in 0 ..< count {
                let next = (index + 1) % count
                let previous = (index + count - 1) % count
                let point = ring.points[index]

                // The vertical bevel at this corner and the triangle over it.
                let drawBack = ring.drawBack[index]
                if drawBack > 0 {
                    let incoming = ring.directions[previous]
                    let outgoing = ring.directions[index]
                    let incomingNormal = leftNormal(incoming)
                    let outgoingNormal = leftNormal(outgoing)
                    let from = point - incoming * drawBack
                    let to = point + outgoing * drawBack
                    let bevelOutward = simd_normalize(incomingNormal + outgoingNormal)
                    builder.appendQuad(corners: [SIMD3(from.x, from.y, bevelBottom), SIMD3(to.x, to.y, bevelBottom),
                                                 SIMD3(to.x, to.y, wallTop), SIMD3(from.x, from.y, wallTop)],
                                       normals: [incomingNormal, outgoingNormal, outgoingNormal, incomingNormal],
                                       outward: bevelOutward)
                    builder.appendTriangle(positions: [SIMD3(point.x, point.y, baseHeight),
                                                       SIMD3(to.x, to.y, bevelBottom), SIMD3(from.x, from.y, bevelBottom)],
                                           normals: [bevelOutward, outgoingNormal, incomingNormal],
                                           outward: simd_normalize(bevelOutward + up))
                    let roofPoint = ring.roofPoint[index]
                    builder.appendTriangle(positions: [SIMD3(from.x, from.y, wallTop), SIMD3(to.x, to.y, wallTop),
                                                       SIMD3(roofPoint.x, roofPoint.y, topHeight)],
                                           normals: [incomingNormal, outgoingNormal, up],
                                           outward: simd_normalize(bevelOutward + up))
                }

                // The wall from this point to the next, and its band up to
                // the roof's rim.
                guard ring.isWall[index] else { continue }
                let direction = ring.directions[index]
                guard direction != .zero else { continue }
                let normal = leftNormal(direction)
                let start = point + direction * ring.drawBack[index]
                let end = ring.points[next] - direction * ring.drawBack[next]
                let footprintEnd = ring.points[next]
                if ring.drawBack[index] > 0 || ring.drawBack[next] > 0 {
                    // From the footprint's corners on the ground to the
                    // drawn-back ends a radius over it, then straight up.
                    builder.appendQuad(corners: [SIMD3(point.x, point.y, baseHeight),
                                                 SIMD3(footprintEnd.x, footprintEnd.y, baseHeight),
                                                 SIMD3(end.x, end.y, bevelBottom), SIMD3(start.x, start.y, bevelBottom)],
                                       normals: [normal, normal, normal, normal],
                                       outward: normal)
                    builder.appendQuad(corners: [SIMD3(start.x, start.y, bevelBottom), SIMD3(end.x, end.y, bevelBottom),
                                                 SIMD3(end.x, end.y, wallTop), SIMD3(start.x, start.y, wallTop)],
                                       normals: [normal, normal, normal, normal],
                                       outward: normal)
                } else {
                    builder.appendQuad(corners: [SIMD3(start.x, start.y, baseHeight), SIMD3(end.x, end.y, baseHeight),
                                                 SIMD3(end.x, end.y, wallTop), SIMD3(start.x, start.y, wallTop)],
                                       normals: [normal, normal, normal, normal],
                                       outward: normal)
                }
                let roofStartPoint = ring.roofPoint[index]
                let roofEndPoint = ring.roofPoint[next]
                builder.appendQuad(corners: [SIMD3(start.x, start.y, wallTop), SIMD3(end.x, end.y, wallTop),
                                             SIMD3(roofEndPoint.x, roofEndPoint.y, topHeight),
                                             SIMD3(roofStartPoint.x, roofStartPoint.y, topHeight)],
                                   normals: [normal, normal, up, up],
                                   outward: simd_normalize(normal + up))
            }
        }

        return builder.indices.isEmpty ? nil : ParsedExtrudedMesh(vertices: builder.vertices, indices: builder.indices)
    }

    /// What every corner of a ring does under the radius.
    private static func roundedRing(_ points: [SIMD2<Float>], radius: Float, tileExtent: Float) -> RoundedRing {
        let count = points.count
        let isWall = (0 ..< count).map { index in
            isBoundaryEdge(points[index], points[(index + 1) % count], tileExtent: tileExtent) == false
        }
        let lengths = (0 ..< count).map { simd_distance(points[$0], points[($0 + 1) % count]) }
        let directions = (0 ..< count).map { index in
            lengths[index] > 0 ? (points[(index + 1) % count] - points[index]) / lengths[index] : .zero
        }
        var drawBack = [Float](repeating: 0, count: count)
        var roofPoint = points
        for index in 0 ..< count {
            let previous = (index + count - 1) % count
            let next = (index + 1) % count
            // A corner at the tile's edge stays sharp and its roof stays on
            // the edge, where the next tile's building goes on.
            guard isWall[previous], isWall[index] else { continue }
            let incomingLength = lengths[previous]
            let outgoingLength = lengths[index]
            guard incomingLength > 0, outgoingLength > 0 else { continue }
            let incoming = directions[previous]
            let outgoing = directions[index]
            let shortest = min(incomingLength, outgoingLength)

            // The walls draw back by the radius times the tangent of half
            // the turn: a right angle draws back by the radius.
            let cosine = min(max(simd_dot(incoming, outgoing), -1), 1)
            let tangentOfHalfTurn = ((1 - cosine) / max(1 + cosine, 1e-4)).squareRoot()
            let back = min(radius * tangentOfHalfTurn, shortest / 3)
            drawBack[index] = back >= minimumEdgeRadius * 0.5 ? back : 0

            // The roof's rim drawn in along the corner's bisector, by the
            // radius from both edges, at most four radii.
            let incomingNormal = leftNormal(incoming)
            let outgoingNormal = leftNormal(outgoing)
            let bisector = incomingNormal + outgoingNormal
            let bisectorLength = simd_length(bisector)
            guard bisectorLength > 1e-4 else { continue }
            let miter = bisector / bisectorLength
            let cosineOfHalfTurn = max(simd_dot(miter, incomingNormal), 0.25)
            let inset = min(radius / cosineOfHalfTurn, radius * 4, shortest / 2)
            roofPoint[index] = points[index] - SIMD2<Float>(miter.x, miter.y) * inset
        }
        return RoundedRing(points: points, directions: directions, isWall: isWall, drawBack: drawBack, roofPoint: roofPoint)
    }

    /// The normal facing out of the material from an edge running along
    /// `direction`: the left side, for an exterior wound clockwise in
    /// render space and a hole counter-clockwise.
    private static func leftNormal(_ direction: SIMD2<Float>) -> SIMD3<Float> {
        SIMD3<Float>(-direction.y, direction.x, 0)
    }

    /// The vertices and the indices, every triangle wound as the walls of
    /// the sharp build are: `cross(c - a, b - a)` faces out of the material.
    private struct MeshBuilder {
        var vertices: [ParsedExtrudedVertex] = []
        var indices: [UInt32] = []

        mutating func appendTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, outward: SIMD3<Float>) {
            let pa = vertices[Int(a)].position
            let pb = vertices[Int(b)].position
            let pc = vertices[Int(c)].position
            let facing = simd_dot(simd_cross(pc - pa, pb - pa), outward)
            guard facing != 0 else { return }
            indices.append(contentsOf: facing > 0 ? [a, b, c] : [a, c, b])
        }

        mutating func appendTriangle(positions: [SIMD3<Float>], normals: [SIMD3<Float>], outward: SIMD3<Float>) {
            let start = UInt32(vertices.count)
            for (position, normal) in zip(positions, normals) {
                vertices.append(ParsedExtrudedVertex(position: position, normal: normal, surfaceID: 0))
            }
            appendTriangle(start, start + 1, start + 2, outward: outward)
        }

        /// A quad given around its edge, as two triangles.
        mutating func appendQuad(corners: [SIMD3<Float>], normals: [SIMD3<Float>], outward: SIMD3<Float>) {
            let start = UInt32(vertices.count)
            for (position, normal) in zip(corners, normals) {
                vertices.append(ParsedExtrudedVertex(position: position, normal: normal, surfaceID: 0))
            }
            appendTriangle(start, start + 1, start + 2, outward: outward)
            appendTriangle(start, start + 2, start + 3, outward: outward)
        }
    }
}
