// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Earcut
import simd
import Mvt

class ParsePolygon {
    private let clipper = Clipper()
    private var earcutCoordinates: [Double] = []
    private var earcutHoleIndices: [Int] = []
    private var earcutVertices: [SIMD2<Int16>] = []
    private static let epsilon: Float = 0.0001

    /// Rings in TILE space (y down, raw MVT), clipped to the tile square:
    /// the space the whole Parse layer works in. See `TileCoordinateSpace`.
    struct ClippedPolygon {
        let exterior: [SIMD2<Float>]
        let interiors: [[SIMD2<Float>]]
    }

    /// `clipped` is tile space; `parsedPolygon` is the tessellated result in
    /// render space (y up), the vertex storage contract. The flip between
    /// them happens once, inside `triangulateGeometry`.
    struct ParsedGeometry {
        let clipped: ClippedPolygon
        let parsedPolygon: TileMvtParser.ParsedPolygon
    }

    private func clip(polygon: Polygon, tileExtent: Float) -> ClippedPolygon? {
        if isFullyInsideTile(ring: polygon.exteriorRing, tileExtent: tileExtent) {
            let exterior = sanitizeRing(convertRing(polygon.exteriorRing, tileExtent: tileExtent))
            guard exterior.count >= 3 else { return nil }

            var interiors: [[SIMD2<Float>]] = []
            interiors.reserveCapacity(polygon.interiorRings.count)
            for ring in polygon.interiorRings {
                let sanitizedInterior = sanitizeRing(convertRing(ring, tileExtent: tileExtent))
                if sanitizedInterior.count >= 3 {
                    interiors.append(sanitizedInterior)
                }
            }
            return ClippedPolygon(exterior: exterior,
                                  interiors: interiors)
        }

        let clipPoly = Clipper.Polygon(points: [
            Clipper.Point(x: 0.0, y: 0.0),
            Clipper.Point(x: Double(tileExtent), y: 0.0),
            Clipper.Point(x: Double(tileExtent), y: Double(tileExtent)),
            Clipper.Point(x: 0.0, y: Double(tileExtent))
        ])

        let exterior = polygon.exteriorRing.map {
            Clipper.Point(x: Double($0.x), y: Double($0.y))
        }
        guard let exteriorClipped = clipper.sutherlandHodgmanClip(subjPoly: Clipper.Polygon(points: exterior),
                                                                  clipPoly: clipPoly) else {
            return nil
        }

        var interiorClipped: [Clipper.Polygon] = []
        interiorClipped.reserveCapacity(polygon.interiorRings.count)
        for ring in polygon.interiorRings {
            let interior = ring.map {
                Clipper.Point(x: Double($0.x), y: Double($0.y))
            }
            if let clipped = clipper.sutherlandHodgmanClip(subjPoly: Clipper.Polygon(points: interior),
                                                           clipPoly: clipPoly) {
                interiorClipped.append(clipped)
            }
        }
        
        let exteriorPoints = sanitizeRing(exteriorClipped.points.map { SIMD2<Float>(Float($0.x), Float($0.y)) })
        if exteriorPoints.count < 3 {
            return nil
        }
        let interiorPoints = interiorClipped.map { ring in
            sanitizeRing(ring.points.map { SIMD2<Float>(Float($0.x), Float($0.y)) })
        }.filter { $0.count >= 3 }
        return ClippedPolygon(exterior: exteriorPoints,
                              interiors: interiorPoints)
    }

    func parseGeometry(polygon: Polygon, tileExtent: Float) -> ParsedGeometry? {
        guard let clipped = clip(polygon: polygon, tileExtent: tileExtent) else { return nil }
        return triangulateGeometry(clipped: clipped, tileExtent: tileExtent)
    }

    func parse(polygon: Polygon, tileExtent: Float) -> TileMvtParser.ParsedPolygon? {
        return parseGeometry(polygon: polygon, tileExtent: tileExtent)?.parsedPolygon
    }

    private func triangulateGeometry(clipped: ClippedPolygon, tileExtent: Float) -> ParsedGeometry? {
        // The one entry into render space for polygon fills. The flip MUST
        // precede the winding decisions (`signedArea`, earcut): reflecting
        // afterward would silently invert every triangle's orientation.
        let renderExterior = TileCoordinateSpace.renderPoints(clipped.exterior)
        if clipped.interiors.isEmpty,
           var polygon = triangulateConvexExterior(exterior: renderExterior) {
            polygon.outlineIndices = Self.outlineIndices(rings: [renderExterior], tileExtent: tileExtent)
            return ParsedGeometry(clipped: clipped,
                                  parsedPolygon: polygon)
        }

        let renderInteriors = clipped.interiors.map(TileCoordinateSpace.renderPoints)
        guard var polygon = triangulateEarcut(exterior: renderExterior,
                                              interiors: renderInteriors) else { return nil }
        // Both tessellators keep the ring vertices in ring order (the
        // exterior first, then each interior), which is what lets the
        // outline index the fill's own vertices.
        polygon.outlineIndices = Self.outlineIndices(rings: [renderExterior] + renderInteriors,
                                                     tileExtent: tileExtent)
        return ParsedGeometry(clipped: clipped,
                              parsedPolygon: polygon)
    }

    /// The ring edges of a tessellated fill as a line list over the fill's
    /// vertex order (`rings` concatenated). An edge that runs along the tile
    /// boundary is the clip, not a feature edge: the polygon continues in
    /// the neighbouring tile, so it gets no outline. Rings are render space,
    /// where the boundary is still the four lines x = 0, x = extent, y = 0,
    /// y = extent.
    static func outlineIndices(rings: [[SIMD2<Float>]], tileExtent: Float) -> [UInt32] {
        var outline: [UInt32] = []
        outline.reserveCapacity(rings.reduce(0) { $0 + $1.count } * 2)
        var base: UInt32 = 0
        for ring in rings {
            defer { base += UInt32(ring.count) }
            guard ring.count >= 2 else { continue }
            for index in 0..<ring.count {
                let next = (index + 1) % ring.count
                if isTileBoundaryEdge(ring[index], ring[next], tileExtent: tileExtent) {
                    continue
                }
                outline.append(base + UInt32(index))
                outline.append(base + UInt32(next))
            }
        }
        return outline
    }

    private static func isTileBoundaryEdge(_ a: SIMD2<Float>, _ b: SIMD2<Float>, tileExtent: Float) -> Bool {
        func onLine(_ value: Float, _ target: Float) -> Bool {
            abs(value - target) <= epsilon
        }
        return (onLine(a.x, 0) && onLine(b.x, 0))
            || (onLine(a.x, tileExtent) && onLine(b.x, tileExtent))
            || (onLine(a.y, 0) && onLine(b.y, 0))
            || (onLine(a.y, tileExtent) && onLine(b.y, tileExtent))
    }

    private func triangulateConvexExterior(exterior: [SIMD2<Float>]) -> TileMvtParser.ParsedPolygon? {
        guard exterior.count >= 3, isConvex(ring: exterior) else { return nil }

        var vertices: [SIMD2<Int16>] = []
        vertices.reserveCapacity(exterior.count)
        for point in exterior {
            vertices.append(toShortVector(point))
        }

        let isClockwise = signedArea(of: exterior) < 0
        var indices: [UInt32] = []
        indices.reserveCapacity(max(0, (exterior.count - 2) * 3))
        for index in 1..<(exterior.count - 1) {
            indices.append(0)
            if isClockwise {
                indices.append(UInt32(index + 1))
                indices.append(UInt32(index))
            } else {
                indices.append(UInt32(index))
                indices.append(UInt32(index + 1))
            }
        }

        return indices.isEmpty ? nil : TileMvtParser.ParsedPolygon(vertices: vertices, indices: indices)
    }

    private func triangulateEarcut(exterior: [SIMD2<Float>],
                                   interiors: [[SIMD2<Float>]]) -> TileMvtParser.ParsedPolygon? {
        earcutCoordinates.removeAll(keepingCapacity: true)
        earcutHoleIndices.removeAll(keepingCapacity: true)
        earcutVertices.removeAll(keepingCapacity: true)

        let totalVertexCount = exterior.count + interiors.reduce(0) { partial, ring in
            partial + ring.count
        }
        earcutCoordinates.reserveCapacity(totalVertexCount * 2)
        earcutHoleIndices.reserveCapacity(interiors.count)
        earcutVertices.reserveCapacity(totalVertexCount)

        appendRing(exterior)
        for ring in interiors {
            earcutHoleIndices.append(earcutVertices.count)
            appendRing(ring)
        }

        let earcutIndices = Earcut.tessellate(data: earcutCoordinates,
                                              holeIndices: earcutHoleIndices,
                                              dim: 2)
        guard earcutIndices.isEmpty == false else { return nil }

        return TileMvtParser.ParsedPolygon(vertices: Array(earcutVertices), indices: earcutIndices)
    }

    private func appendRing(_ ring: [SIMD2<Float>]) {
        for point in ring {
            earcutVertices.append(toShortVector(point))
            earcutCoordinates.append(Double(point.x))
            earcutCoordinates.append(Double(point.y))
        }
    }

    private func isFullyInsideTile(ring: [Point], tileExtent: Float) -> Bool {
        guard let first = ring.first else { return false }

        var minX = Float(first.x)
        var maxX = Float(first.x)
        var minY = Float(first.y)
        var maxY = Float(first.y)

        for point in ring.dropFirst() {
            let x = Float(point.x)
            let y = Float(point.y)
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        return minX >= 0 && maxX <= tileExtent && minY >= 0 && maxY <= tileExtent
    }

    private func convertRing(_ ring: [Point], tileExtent: Float) -> [SIMD2<Float>] {
        var converted: [SIMD2<Float>] = []
        converted.reserveCapacity(ring.count)
        for point in ring {
            converted.append(SIMD2<Float>(Float(point.x), Float(point.y)))
        }
        return converted
    }

    private func sanitizeRing(_ ring: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard ring.isEmpty == false else { return [] }

        var ringPoints = ring
        if let last = ringPoints.last, let first = ringPoints.first, pointsEqual(last, first) {
            ringPoints.removeLast()
        }

        var filtered: [SIMD2<Float>] = []
        filtered.reserveCapacity(ringPoints.count)
        for point in ringPoints {
            if let last = filtered.last, pointsEqual(last, point) {
                continue
            }
            if filtered.count >= 2, pointsEqual(filtered[filtered.count - 2], point) {
                filtered.removeLast()
                continue
            }
            filtered.append(point)
        }

        if let last = filtered.last, let first = filtered.first, pointsEqual(last, first) {
            filtered.removeLast()
        }
        return filtered
    }

    private func isConvex(ring: [SIMD2<Float>]) -> Bool {
        guard ring.count >= 3 else { return false }

        var expectedSign: Float = 0
        for index in 0..<ring.count {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            let c = ring[(index + 2) % ring.count]
            let cross = crossZ(b - a, c - b)
            if abs(cross) <= Self.epsilon {
                continue
            }

            if expectedSign == 0 {
                expectedSign = cross > 0 ? 1 : -1
                continue
            }

            if cross * expectedSign < 0 {
                return false
            }
        }

        return expectedSign != 0
    }

    private func signedArea(of ring: [SIMD2<Float>]) -> Float {
        guard ring.count >= 3 else { return 0 }

        var area: Float = 0
        for index in 0..<ring.count {
            let nextIndex = (index + 1) % ring.count
            area += ring[index].x * ring[nextIndex].y - ring[nextIndex].x * ring[index].y
        }
        return area * 0.5
    }

    private func crossZ(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Float {
        lhs.x * rhs.y - lhs.y * rhs.x
    }

    private func pointsEqual(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Bool {
        simd_length_squared(lhs - rhs) <= Self.epsilon * Self.epsilon
    }

    private func toShortVector(_ value: SIMD2<Float>) -> SIMD2<Int16> {
        let x = Int16(clamping: Int(value.x.rounded()))
        let y = Int16(clamping: Int(value.y.rounded()))
        return SIMD2<Int16>(x, y)
    }
}
