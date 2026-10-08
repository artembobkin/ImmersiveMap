// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One tessellated polygon in render space (x east, y up, float tile
/// units): a fill, a line ribbon or a decoration, before the unification
/// stage packs it into a layer's streams.
struct ParsedPolygon {
    var vertices: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    /// Per-vertex signed distance from a line's centerline, normalized so
    /// the extruded rim is ±`Int8.max`. Empty for plain polygon geometry;
    /// when non-empty it runs in lockstep with `vertices`.
    var lineDistances: [Int8] = []
    /// Per-vertex longitudinal parameter, lockstep with `lineDistances`;
    /// see `TileVertexIn.lineParameter` for the two interpretations
    /// (end-feather distance for solid styles, arc length for
    /// point-dashed ones).
    var lineParameters: [Int16] = []
    /// A deferred ribbon (`ParseLine.parse(deferredExtrusion:)`): every
    /// vertex is a point of the centreline and this is the unit direction,
    /// snorm Int8, the vertex shader extrudes it along by the width the
    /// style resolves on screen; zero for a centreline vertex itself (a
    /// join's or a cap's hub). Empty for pre-extruded ribbons and fills,
    /// whose vertices are final. Lockstep with `vertices` when non-empty.
    var lineNormals: [SIMD2<Int8>] = []
    /// A deferred ribbon's edge lines: the rim as a list of line segments,
    /// two indices each, over the rim vertices `indices` reads too. The
    /// road buckets draw them apart from the body, as one-pixel lines at
    /// half the road's alpha that soften its hard edge
    /// (`TileUnificationStage`). Empty for everything else.
    var edgeLineIndices: [UInt32] = []

    /// A line ribbon carries per-vertex line attributes (extruded stroke
    /// geometry); a fill does not, including the decoration polygons that
    /// share a line style (they default to the saturated line interior).
    /// The unification stage sweeps the two classes apart, and
    /// `GroundGeometrySubdivider`'s ribbon grid is coarser.
    var isLineRibbon: Bool {
        lineDistances.count == vertices.count
            && lineParameters.count == vertices.count
    }

    /// Gives a fill the line attributes of the saturated line interior (on
    /// the centreline, far from any end), the values an attribute-less
    /// polygon defaults to. The fill then sweeps with the ribbons and draws
    /// among the ground lines by its key, fully covered
    /// (`FillStyle.drawsAmongGroundLines`).
    mutating func makeLineClassFill() {
        lineDistances = [Int8](repeating: 0, count: vertices.count)
        lineParameters = [Int16](repeating: Int16.max, count: vertices.count)
        lineNormals = []
    }
}

extension ParsedPolygon {
    /// The winding contract of every tile triangle: counter-clockwise in
    /// render space (x east, y up). That is the front face the tile drawers
    /// keep when they cull back faces (on the sphere the far side of the
    /// planet is clockwise on screen and disappears by orientation alone).
    /// Every emitter honours it by construction; this is how the tests and
    /// the debug funnel in `TileUnificationStage.appendPolygon` check it.
    ///
    /// How far below zero the doubled signed area may go before a triangle
    /// counts as clockwise, per unit of its longest edge. The vertices are
    /// the tessellator's floats, so only the float arithmetic itself can
    /// turn a sliver's area negative: the allowance is a small fraction of
    /// a unit per unit of edge, far under any real feature's area. A
    /// clockwise emitter is off by the feature's whole area and is caught.
    static let clockwiseTolerancePerEdgeUnit: Double = 1e-3

    /// Turns every clockwise triangle counter-clockwise by swapping two of
    /// its indices, judged on the vertices as they are. A tessellator
    /// decides its winding on the ring, and earcut hands a ring back with
    /// the odd inverted ear. A flipped triangle covers the same ground
    /// either way, and a degenerate one is left alone. In place, no
    /// allocation.
    mutating func windCounterClockwise() {
        var start = 0
        while start + 2 < indices.count {
            let a = vertices[Int(indices[start])]
            let b = vertices[Int(indices[start + 1])]
            let c = vertices[Int(indices[start + 2])]
            if Self.doubledArea(a, b, c) < 0 {
                indices.swapAt(start + 1, start + 2)
            }
            start += 3
        }
    }

    /// The doubled signed area of a triangle, positive counter-clockwise in
    /// render space, in double so a large triangle's corners do not lose
    /// the sliver's sign.
    static func doubledArea(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Double {
        (Double(b.x) - Double(a.x)) * (Double(c.y) - Double(a.y))
            - (Double(b.y) - Double(a.y)) * (Double(c.x) - Double(a.x))
    }

    /// Index (in triangles) of the first triangle wound clockwise in render
    /// space by more than the vertex rounding can explain, or nil when every
    /// triangle is counter-clockwise or degenerate.
    static func firstClockwiseTriangle(vertices: [SIMD2<Float>], indices: [UInt32]) -> Int? {
        var start = 0
        while start + 2 < indices.count {
            let a = vertices[Int(indices[start])]
            let b = vertices[Int(indices[start + 1])]
            let c = vertices[Int(indices[start + 2])]
            let doubled = doubledArea(a, b, c)
            if doubled < 0 {
                func squaredLength(_ p: SIMD2<Float>, _ q: SIMD2<Float>) -> Double {
                    let dx = Double(q.x) - Double(p.x)
                    let dy = Double(q.y) - Double(p.y)
                    return dx * dx + dy * dy
                }
                let longestEdge = max(squaredLength(a, b), squaredLength(b, c), squaredLength(c, a)).squareRoot()
                if doubled < -(clockwiseTolerancePerEdgeUnit * longestEdge + 1e-3) {
                    return start / 3
                }
            }
            start += 3
        }
        return nil
    }

    /// A convex ring in render space, fanned from its first vertex and wound
    /// counter-clockwise whichever way the ring runs, the same decision
    /// `ParsePolygon`'s convex fan and `ParseLine`'s clip make.
    static func counterClockwiseConvexFan(_ ring: [SIMD2<Float>]) -> ParsedPolygon {
        var doubledArea: Float = 0
        for index in ring.indices {
            let current = ring[index]
            let next = ring[(index + 1) % ring.count]
            doubledArea += current.x * next.y - next.x * current.y
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(max(0, ring.count - 2) * 3)
        for corner in 1..<max(1, ring.count - 1) {
            indices.append(0)
            if doubledArea < 0 {
                indices.append(UInt32(corner + 1))
                indices.append(UInt32(corner))
            } else {
                indices.append(UInt32(corner))
                indices.append(UInt32(corner + 1))
            }
        }
        return ParsedPolygon(vertices: ring, indices: indices)
    }
}
