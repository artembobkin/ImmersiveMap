// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct ParsedPolygon {
        var vertices: [SIMD2<Int16>] = []
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
        /// The polygon's ring edges as a line list (pairs of indices into
        /// `vertices`), for the fill-outline antialiasing pass: the flat
        /// drawer rasterizes them as one-pixel line primitives in the fill's
        /// colour over the fill's own staircase edge (the `fill-antialias`
        /// construction of Mapbox GL). Edges lying on the tile boundary are
        /// left out, since the polygon continues in the neighbour. Empty for
        /// line ribbons and for every polygon that is not a plain fill.
        var outlineIndices: [UInt32] = []
    }
}

extension TileMvtParser.ParsedPolygon {
    /// The winding contract of every tile triangle: counter-clockwise in
    /// render space (x east, y up). That is the front face the tile drawers
    /// keep when they cull back faces (on the sphere the far side of the
    /// planet is clockwise on screen and disappears by orientation alone).
    /// Every emitter honours it by construction; this is how the tests and
    /// the debug funnel in `TileMvtParser.appendPolygon` check it.
    ///
    /// How far below zero the doubled signed area may go before a triangle
    /// counts as clockwise, per unit of its longest edge. Rounding the
    /// vertices to the Int16 grid moves each by up to 0.71 units, which
    /// changes the doubled area of a sliver (two long edges, one short) by
    /// up to about 1.4 times its length: a sliver thinner than the grid can
    /// come out inside out, and such a sliver is invisible either way. A
    /// clockwise emitter is off by the feature's whole area: at this factor
    /// a ribbon just over 1.5 units wide is caught, and the thinnest real
    /// stroke (the 0.35 metre marking at z16) is 2.3 units.
    static let clockwiseTolerancePerEdgeUnit: Double = 1.5

    /// Index (in triangles) of the first triangle wound clockwise in render
    /// space by more than the vertex rounding can explain, or nil when every
    /// triangle is counter-clockwise or degenerate.
    static func firstClockwiseTriangle(vertices: [SIMD2<Int16>], indices: [UInt32]) -> Int? {
        var start = 0
        while start + 2 < indices.count {
            let a = vertices[Int(indices[start])]
            let b = vertices[Int(indices[start + 1])]
            let c = vertices[Int(indices[start + 2])]
            let doubled = (Int64(b.x) - Int64(a.x)) * (Int64(c.y) - Int64(a.y))
                - (Int64(b.y) - Int64(a.y)) * (Int64(c.x) - Int64(a.x))
            if doubled < 0 {
                func squaredLength(_ p: SIMD2<Int16>, _ q: SIMD2<Int16>) -> Double {
                    let dx = Double(q.x) - Double(p.x)
                    let dy = Double(q.y) - Double(p.y)
                    return dx * dx + dy * dy
                }
                let longestEdge = max(squaredLength(a, b), squaredLength(b, c), squaredLength(c, a)).squareRoot()
                if Double(doubled) < -(clockwiseTolerancePerEdgeUnit * longestEdge + 8) {
                    return start / 3
                }
            }
            start += 3
        }
        return nil
    }

    /// A convex ring in render space, fanned from its first vertex and wound
    /// counter-clockwise whichever way the ring runs: the orientation is
    /// decided on the floats, before the Int16 rounding, the same decision
    /// `ParsePolygon`'s convex fan and `ParseLine`'s clip make.
    static func counterClockwiseConvexFan(_ ring: [SIMD2<Float>]) -> TileMvtParser.ParsedPolygon {
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
        return TileMvtParser.ParsedPolygon(vertices: ring.map(TileCoordinateSpace.quantized),
                                           indices: indices)
    }
}
