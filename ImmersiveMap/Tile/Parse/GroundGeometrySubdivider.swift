// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Splits the ground geometry of a coarse tile on a regular grid so it can
/// be drawn straight onto the sphere.
///
/// A tile-spanning triangle drawn on the globe is a chord: at z0 the
/// background quad's diagonal would cut through the planet by a quarter of
/// its radius. The surface morph projects vertices, not edges, so the only
/// way to follow the curvature is more vertices. Every triangle of every
/// ground polygon (fills and line ribbons alike) is cut along the grid lines
/// `x = k * step` and `y = m * step`, each piece fan-triangulated; the step
/// per tile zoom keeps the chord sag of one cell under about half a pixel at
/// the zoom the tile is native to (edge angle theta = 2 pi step / (4096 2^z),
/// sag = R theta^2 / 8, with the sphere's screen radius doubling per zoom).
/// Tiles from z10 are never on the sphere: the surface has unfurled by then.
///
/// Attributes ride along linearly (the signed line distance is a linear
/// field across a ribbon, the arc length linear along it), so the analytic
/// antialiasing and the dashes survive the split unchanged. Intersections
/// are computed from lexicographically ordered edge endpoints, so the two
/// triangles sharing an edge produce bit-identical split vertices and no
/// hairline opens inside a polygon. Baked into the prepared tile, hence part
/// of `PreparedTileDiskCaching.preparedFormatVersion`.
enum GroundGeometrySubdivider {
    /// Grid step in tile units for the tile zoom, nil where no split is
    /// needed. z8 and z9 are insurance for a finer tile retained on the
    /// sphere while the surface unfurls.
    static func step(forTileZoom zoom: Int) -> Int? {
        switch zoom {
        case ...1: return 64
        case 2...3: return 128
        case 4...5: return 256
        case 6...7: return 512
        case 8...9: return 1024
        default: return nil
        }
    }

    static func subdivideIfNeeded(_ polygonByStyle: inout [UInt8: [TileMvtParser.ParsedPolygon]],
                                  tileZoom: Int) {
        guard let step = step(forTileZoom: tileZoom) else { return }
        for key in polygonByStyle.keys {
            guard let polygons = polygonByStyle[key] else { continue }
            polygonByStyle[key] = polygons.map { subdivide($0, step: step) }
        }
    }

    /// One vertex with its attributes in float, the working form of a piece.
    struct Point: Equatable {
        var position: SIMD2<Float>
        var lineDistance: Float
        var lineParameter: Float
    }

    static func subdivide(_ polygon: TileMvtParser.ParsedPolygon, step: Int) -> TileMvtParser.ParsedPolygon {
        guard step > 0, polygon.indices.count >= 3 else { return polygon }
        let hasAttributes = polygon.lineDistances.count == polygon.vertices.count
            && polygon.lineParameters.count == polygon.vertices.count
        let stepValue = Float(step)

        var output = TileMvtParser.ParsedPolygon()
        output.vertices.reserveCapacity(polygon.vertices.count)
        output.indices.reserveCapacity(polygon.indices.count)
        if hasAttributes {
            output.lineDistances.reserveCapacity(polygon.vertices.count)
            output.lineParameters.reserveCapacity(polygon.vertices.count)
        }
        var vertexIndexByKey: [VertexKey: UInt32] = [:]
        vertexIndexByKey.reserveCapacity(polygon.vertices.count)

        func point(at index: UInt32) -> Point {
            let vertex = polygon.vertices[Int(index)]
            return Point(position: SIMD2<Float>(Float(vertex.x), Float(vertex.y)),
                         lineDistance: hasAttributes ? Float(polygon.lineDistances[Int(index)]) : 0,
                         lineParameter: hasAttributes ? Float(polygon.lineParameters[Int(index)]) : 0)
        }

        func emit(_ point: Point) -> UInt32 {
            let quantized = quantize(point)
            let key = VertexKey(position: quantized.position,
                                lineDistance: quantized.lineDistance,
                                lineParameter: quantized.lineParameter)
            if let existing = vertexIndexByKey[key] {
                return existing
            }
            let index = UInt32(output.vertices.count)
            output.vertices.append(quantized.position)
            if hasAttributes {
                output.lineDistances.append(quantized.lineDistance)
                output.lineParameters.append(quantized.lineParameter)
            }
            vertexIndexByKey[key] = index
            return index
        }

        func emitTriangle(_ a: Point, _ b: Point, _ c: Point) {
            let ia = emit(a)
            let ib = emit(b)
            let ic = emit(c)
            guard ia != ib, ib != ic, ia != ic else { return }
            output.indices.append(ia)
            output.indices.append(ib)
            output.indices.append(ic)
        }

        var triangle = 0
        while triangle + 2 < polygon.indices.count {
            let a = point(at: polygon.indices[triangle])
            let b = point(at: polygon.indices[triangle + 1])
            let c = point(at: polygon.indices[triangle + 2])
            triangle += 3
            let minX = min(a.position.x, b.position.x, c.position.x)
            let maxX = max(a.position.x, b.position.x, c.position.x)
            let minY = min(a.position.y, b.position.y, c.position.y)
            let maxY = max(a.position.y, b.position.y, c.position.y)
            let firstColumn = Int((minX / stepValue).rounded(.down)) + 1
            let lastColumn = Int(((maxX - 1e-3) / stepValue).rounded(.down))
            let firstRow = Int((minY / stepValue).rounded(.down)) + 1
            let lastRow = Int(((maxY - 1e-3) / stepValue).rounded(.down))
            if firstColumn > lastColumn, firstRow > lastRow {
                emitTriangle(a, b, c)
                continue
            }
            var pieces: [[Point]] = [[a, b, c]]
            if firstColumn <= lastColumn {
                for column in firstColumn...lastColumn {
                    pieces = pieces.flatMap { split($0, axis: 0, at: Float(column) * stepValue) }
                }
            }
            if firstRow <= lastRow {
                for row in firstRow...lastRow {
                    pieces = pieces.flatMap { split($0, axis: 1, at: Float(row) * stepValue) }
                }
            }
            for piece in pieces where piece.count >= 3 {
                for corner in 1..<(piece.count - 1) {
                    emitTriangle(piece[0], piece[corner], piece[corner + 1])
                }
            }
        }
        return output
    }

    /// Splits a convex polygon along the line `position[axis] == value`
    /// into the piece below and the piece above (either may be empty),
    /// keeping the input winding.
    static func split(_ polygon: [Point], axis: Int, at value: Float) -> [[Point]] {
        var below: [Point] = []
        var above: [Point] = []
        below.reserveCapacity(polygon.count + 1)
        above.reserveCapacity(polygon.count + 1)
        for index in 0..<polygon.count {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            let currentSide = current.position[axis] - value
            let nextSide = next.position[axis] - value
            if currentSide <= 0 { below.append(current) }
            if currentSide >= 0 { above.append(current) }
            if (currentSide < 0 && nextSide > 0) || (currentSide > 0 && nextSide < 0) {
                let crossing = intersection(current, next, axis: axis, at: value)
                below.append(crossing)
                above.append(crossing)
            }
        }
        var result: [[Point]] = []
        if below.count >= 3 { result.append(below) }
        if above.count >= 3 { result.append(above) }
        return result
    }

    /// The crossing of an edge with an axis-aligned line, computed from the
    /// edge's endpoints in a canonical order so that both polygons sharing
    /// the edge get the same vertex.
    static func intersection(_ a: Point, _ b: Point, axis: Int, at value: Float) -> Point {
        let (first, second) = isOrderedBefore(a, b) ? (a, b) : (b, a)
        let span = second.position[axis] - first.position[axis]
        let t = span == 0 ? 0 : (value - first.position[axis]) / span
        var position = first.position + (second.position - first.position) * t
        position[axis] = value
        return Point(position: position,
                     lineDistance: first.lineDistance + (second.lineDistance - first.lineDistance) * t,
                     lineParameter: first.lineParameter + (second.lineParameter - first.lineParameter) * t)
    }

    private static func isOrderedBefore(_ a: Point, _ b: Point) -> Bool {
        if a.position.x != b.position.x { return a.position.x < b.position.x }
        if a.position.y != b.position.y { return a.position.y < b.position.y }
        if a.lineDistance != b.lineDistance { return a.lineDistance < b.lineDistance }
        return a.lineParameter < b.lineParameter
    }

    private struct VertexKey: Hashable {
        let position: SIMD2<Int16>
        let lineDistance: Int8
        let lineParameter: Int16
    }

    private static func quantize(_ point: Point) -> (position: SIMD2<Int16>, lineDistance: Int8, lineParameter: Int16) {
        (SIMD2<Int16>(Int16(clamping: Int(point.position.x.rounded())),
                      Int16(clamping: Int(point.position.y.rounded()))),
         Int8(clamping: Int(point.lineDistance.rounded())),
         Int16(clamping: Int(point.lineParameter.rounded())))
    }
}
