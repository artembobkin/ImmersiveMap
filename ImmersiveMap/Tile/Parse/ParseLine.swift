// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct ClippedLineFragment {
    let points: [SIMD2<Float>]
    let startClipped: Bool
    let endClipped: Bool
}

final class LineClipper {
    private static let epsilon: Float = 0.0001

    private struct ClipBounds {
        let minX: Float
        let maxX: Float
        let minY: Float
        let maxY: Float
    }

    private struct ClippedSegment {
        let start: SIMD2<Float>
        let end: SIMD2<Float>
        let startClipped: Bool
        let endClipped: Bool
    }

    func clip(line: LineString, tileExtent: Float, padding: Float = 0) -> [ClippedLineFragment] {
        let points = line.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        return clip(points: points, tileExtent: tileExtent, padding: padding)
    }

    func clip(points: [SIMD2<Float>], tileExtent: Float, padding: Float = 0) -> [ClippedLineFragment] {
        guard points.count >= 2 else { return [] }
        let bounds = ClipBounds(minX: -padding,
                                maxX: tileExtent + padding,
                                minY: -padding,
                                maxY: tileExtent + padding)

        var fragments: [ClippedLineFragment] = []
        var currentPoints: [SIMD2<Float>] = []
        var currentStartClipped = false
        var currentEndClipped = false

        func finalizeCurrentFragment() {
            let sanitized = sanitize(points: currentPoints, bounds: bounds)
            guard sanitized.count >= 2 else {
                currentPoints.removeAll(keepingCapacity: true)
                currentStartClipped = false
                currentEndClipped = false
                return
            }

            fragments.append(ClippedLineFragment(points: sanitized,
                                                startClipped: currentStartClipped,
                                                endClipped: currentEndClipped))
            currentPoints.removeAll(keepingCapacity: true)
            currentStartClipped = false
            currentEndClipped = false
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]

            guard let clippedSegment = clipSegment(start: start, end: end, bounds: bounds) else {
                finalizeCurrentFragment()
                continue
            }

            let clippedStart = Self.clampToBounds(clippedSegment.start, bounds: bounds)
            let clippedEnd = Self.clampToBounds(clippedSegment.end, bounds: bounds)

            if currentPoints.isEmpty {
                currentPoints.append(clippedStart)
                currentStartClipped = clippedSegment.startClipped
            } else if pointsEqual(currentPoints[currentPoints.count - 1], clippedStart) == false {
                finalizeCurrentFragment()
                currentPoints.append(clippedStart)
                currentStartClipped = clippedSegment.startClipped
            }

            if pointsEqual(currentPoints[currentPoints.count - 1], clippedEnd) == false {
                currentPoints.append(clippedEnd)
            }
            currentEndClipped = clippedSegment.endClipped
        }

        finalizeCurrentFragment()
        return fragments
    }

    static func isOnTileBoundary(_ point: SIMD2<Float>, tileExtent: Float) -> Bool {
        abs(point.x) <= Self.epsilon ||
        abs(point.y) <= Self.epsilon ||
        abs(point.x - tileExtent) <= Self.epsilon ||
        abs(point.y - tileExtent) <= Self.epsilon
    }

    private func clipSegment(start: SIMD2<Float>,
                             end: SIMD2<Float>,
                             bounds: ClipBounds) -> ClippedSegment? {
        let delta = end - start
        var t0: Float = 0.0
        var t1: Float = 1.0

        let p: [Float] = [-delta.x, delta.x, -delta.y, delta.y]
        let q: [Float] = [
            start.x - bounds.minX,
            bounds.maxX - start.x,
            start.y - bounds.minY,
            bounds.maxY - start.y
        ]

        for index in 0..<4 {
            let edgeP = p[index]
            let edgeQ = q[index]

            if abs(edgeP) <= Self.epsilon {
                if edgeQ < 0 {
                    return nil
                }
                continue
            }

            let ratio = edgeQ / edgeP
            if edgeP < 0 {
                if ratio > t1 {
                    return nil
                }
                t0 = max(t0, ratio)
            } else {
                if ratio < t0 {
                    return nil
                }
                t1 = min(t1, ratio)
            }
        }

        if t0 > t1 {
            return nil
        }

        let clippedStart = start + delta * t0
        let clippedEnd = start + delta * t1
        if pointsEqual(clippedStart, clippedEnd) {
            return nil
        }

        return ClippedSegment(start: clippedStart,
                              end: clippedEnd,
                              startClipped: t0 > Self.epsilon,
                              endClipped: t1 < 1.0 - Self.epsilon)
    }

    private func sanitize(points: [SIMD2<Float>], bounds: ClipBounds) -> [SIMD2<Float>] {
        guard points.isEmpty == false else { return [] }

        var sanitized: [SIMD2<Float>] = []
        sanitized.reserveCapacity(points.count)
        for point in points {
            let clamped = Self.clampToBounds(point, bounds: bounds)
            if let last = sanitized.last, pointsEqual(last, clamped) {
                continue
            }
            sanitized.append(clamped)
        }
        return sanitized
    }

    private static func clampToBounds(_ point: SIMD2<Float>, bounds: ClipBounds) -> SIMD2<Float> {
        SIMD2<Float>(min(max(point.x, bounds.minX), bounds.maxX),
                     min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func pointsEqual(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Bool {
        abs(lhs.x - rhs.x) <= Self.epsilon && abs(lhs.y - rhs.y) <= Self.epsilon
    }
}

class ParseLine {
    private static let epsilon: Float = 0.0001
    private static let capSegments: Int = 8
    private static let capUnitSemicircle: [SIMD2<Float>] = {
        var template: [SIMD2<Float>] = []
        template.reserveCapacity(capSegments + 1)
        for index in 0...capSegments {
            let t = Float(index) / Float(capSegments)
            let angle = (-0.5 + t) * Float.pi
            template.append(SIMD2<Float>(cos(angle), sin(angle)))
        }
        return template
    }()

    private let clipper = Clipper()

    private struct GeneratedPolygon {
        var vertices: [SIMD2<Float>] = []
        var indices: [UInt32] = []
    }

    private struct PrecomputedLine {
        let points: [SIMD2<Float>]
        let segmentLengths: [Float]
        let segmentDirections: [SIMD2<Float>]
        let segmentNormals: [SIMD2<Float>]
        let validSegmentCount: Int
        let firstValidSegmentIndex: Int?
        let lastValidSegmentIndex: Int?
        let joinCount: Int
    }

    func parse(line: LineString,
               width: Double,
               tileExtent: Float,
               lineCapRound: Bool,
               lineJoinRound: Bool) -> TileMvtParser.ParsedPolygon? {
        let points = line.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let startCapRound = lineCapRound && points.first.map { isStrictlyInsideTile($0, tileExtent: tileExtent) } == true
        let endCapRound = lineCapRound && points.last.map { isStrictlyInsideTile($0, tileExtent: tileExtent) } == true
        return parse(points: points,
                     width: width,
                     tileExtent: tileExtent,
                     startCapRound: startCapRound,
                     endCapRound: endCapRound,
                     lineJoinRound: lineJoinRound)
    }

    func parse(points: [SIMD2<Float>],
               width: Double,
               tileExtent: Float,
               startCapRound: Bool,
               endCapRound: Bool,
               lineJoinRound: Bool,
               extendClippedStart: Bool = false,
               extendClippedEnd: Bool = false,
               clipPadding: Float = 0,
               clipGeometryToTileBounds: Bool = true) -> TileMvtParser.ParsedPolygon? {
        guard points.count >= 2, width > 0 else { return nil }

        let halfWidth = Float(width * 0.5)
        let effectivePoints = extendedEndpoints(points: points,
                                                tileExtent: tileExtent,
                                                clipPadding: clipPadding,
                                                extendStart: extendClippedStart,
                                                extendEnd: extendClippedEnd)
        let precomputed = precompute(points: effectivePoints, tileExtent: tileExtent)
        guard precomputed.validSegmentCount > 0 else { return nil }

        var polygon = GeneratedPolygon()
        reserveCapacity(for: precomputed,
                        startCapRound: startCapRound,
                        endCapRound: endCapRound,
                        lineJoinRound: lineJoinRound,
                        vertices: &polygon.vertices,
                        indices: &polygon.indices)

        if startCapRound == false && endCapRound == false && lineJoinRound == false {
            appendSegments(precomputed: precomputed,
                           halfWidth: halfWidth,
                          vertices: &polygon.vertices,
                          indices: &polygon.indices)
            return finalizePolygon(polygon, tileExtent: tileExtent, clipGeometryToTileBounds: clipGeometryToTileBounds)
        }

        appendSegments(precomputed: precomputed,
                       halfWidth: halfWidth,
                       vertices: &polygon.vertices,
                       indices: &polygon.indices)

        if lineJoinRound {
            appendRoundJoins(precomputed: precomputed,
                             halfWidth: halfWidth,
                             vertices: &polygon.vertices,
                             indices: &polygon.indices)
        }

        if startCapRound {
            if let startSegmentIndex = precomputed.firstValidSegmentIndex {
                appendCap(center: precomputed.points[0],
                          direction: precomputed.segmentDirections[startSegmentIndex],
                          radius: halfWidth,
                          flipDirection: true,
                          vertices: &polygon.vertices,
                          indices: &polygon.indices)
            }
        }

        if endCapRound {
            if let endSegmentIndex = precomputed.lastValidSegmentIndex {
                appendCap(center: precomputed.points[points.count - 1],
                          direction: precomputed.segmentDirections[endSegmentIndex],
                          radius: halfWidth,
                          flipDirection: false,
                          vertices: &polygon.vertices,
                          indices: &polygon.indices)
            }
        }

        return finalizePolygon(polygon, tileExtent: tileExtent, clipGeometryToTileBounds: clipGeometryToTileBounds)
    }

    private func finalizePolygon(_ polygon: GeneratedPolygon,
                                 tileExtent: Float,
                                 clipGeometryToTileBounds: Bool) -> TileMvtParser.ParsedPolygon? {
        if clipGeometryToTileBounds {
            return clipToTile(polygon: polygon, tileExtent: tileExtent)
        }
        return quantize(polygon: polygon)
    }

    private func extendedEndpoints(points: [SIMD2<Float>],
                                   tileExtent: Float,
                                   clipPadding: Float,
                                   extendStart: Bool,
                                   extendEnd: Bool) -> [SIMD2<Float>] {
        guard (extendStart || extendEnd), points.count >= 2, clipPadding > Self.epsilon else {
            return points
        }

        var adjusted = points

        if extendStart,
           let startDirection = endpointDirection(points: adjusted, fromStart: true) {
            let extensionLength = clippedEndpointExtensionLength(point: adjusted[0],
                                                                 direction: startDirection,
                                                                 tileExtent: tileExtent,
                                                                 clipPadding: clipPadding)
            adjusted[0] -= startDirection * extensionLength
        }

        if extendEnd,
           let endDirection = endpointDirection(points: adjusted, fromStart: false) {
            let extensionLength = clippedEndpointExtensionLength(point: adjusted[adjusted.count - 1],
                                                                 direction: endDirection,
                                                                 tileExtent: tileExtent,
                                                                 clipPadding: clipPadding)
            adjusted[adjusted.count - 1] += endDirection * extensionLength
        }

        return adjusted
    }

    private func clippedEndpointExtensionLength(point: SIMD2<Float>,
                                                direction: SIMD2<Float>,
                                                tileExtent: Float,
                                                clipPadding: Float) -> Float {
        let minBound = -clipPadding
        let maxBound = tileExtent + clipPadding
        var extensionLength: Float = clipPadding

        if abs(point.x - minBound) <= Self.epsilon || abs(point.x - maxBound) <= Self.epsilon {
            extensionLength = max(extensionLength, clipPadding / max(abs(direction.x), Self.epsilon))
        }

        if abs(point.y - minBound) <= Self.epsilon || abs(point.y - maxBound) <= Self.epsilon {
            extensionLength = max(extensionLength, clipPadding / max(abs(direction.y), Self.epsilon))
        }

        return extensionLength
    }

    private func endpointDirection(points: [SIMD2<Float>], fromStart: Bool) -> SIMD2<Float>? {
        guard points.count >= 2 else { return nil }

        if fromStart {
            let anchor = points[0]
            for index in 1..<points.count {
                let delta = points[index] - anchor
                let length = simd_length(delta)
                if length > Self.epsilon {
                    return delta / length
                }
            }
            return nil
        }

        let anchor = points[points.count - 1]
        if points.count >= 2 {
            for index in stride(from: points.count - 2, through: 0, by: -1) {
                let delta = anchor - points[index]
                let length = simd_length(delta)
                if length > Self.epsilon {
                    return delta / length
                }
            }
        }
        return nil
    }

    private func precompute(points sourcePoints: [SIMD2<Float>], tileExtent: Float) -> PrecomputedLine {
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(sourcePoints.count)
        for point in sourcePoints {
            points.append(SIMD2<Float>(point.x, tileExtent - point.y))
        }

        let segmentCount = max(0, sourcePoints.count - 1)
        var segmentLengths = Array(repeating: Float.zero, count: segmentCount)
        var segmentDirections = Array(repeating: SIMD2<Float>(0, 0), count: segmentCount)
        var segmentNormals = Array(repeating: SIMD2<Float>(0, 0), count: segmentCount)
        var validSegmentCount = 0
        var firstValidSegmentIndex: Int? = nil
        var lastValidSegmentIndex: Int? = nil

        for index in 0..<segmentCount {
            let delta = points[index + 1] - points[index]
            let length = simd_length(delta)
            segmentLengths[index] = length
            if length <= Self.epsilon {
                continue
            }

            let direction = delta / length
            segmentDirections[index] = direction
            segmentNormals[index] = SIMD2<Float>(-direction.y, direction.x)
            validSegmentCount += 1
            if firstValidSegmentIndex == nil {
                firstValidSegmentIndex = index
            }
            lastValidSegmentIndex = index
        }

        var joinCount = 0
        if sourcePoints.count > 2 {
            for index in 1..<(sourcePoints.count - 1) {
                if segmentLengths[index - 1] <= Self.epsilon || segmentLengths[index] <= Self.epsilon {
                    continue
                }
                let dir0 = segmentDirections[index - 1]
                let dir1 = segmentDirections[index]
                let cross = dir0.x * dir1.y - dir0.y * dir1.x
                if abs(cross) <= Self.epsilon {
                    continue
                }
                joinCount += 1
            }
        }

        return PrecomputedLine(points: points,
                               segmentLengths: segmentLengths,
                               segmentDirections: segmentDirections,
                               segmentNormals: segmentNormals,
                               validSegmentCount: validSegmentCount,
                               firstValidSegmentIndex: firstValidSegmentIndex,
                               lastValidSegmentIndex: lastValidSegmentIndex,
                               joinCount: joinCount)
    }

    private func reserveCapacity(for precomputed: PrecomputedLine,
                                 startCapRound: Bool,
                                 endCapRound: Bool,
                                 lineJoinRound: Bool,
                                 vertices: inout [SIMD2<Float>],
                                 indices: inout [UInt32]) {
        let segmentVertices = precomputed.validSegmentCount * 4
        let segmentIndices = precomputed.validSegmentCount * 6
        let joinVertices = lineJoinRound ? precomputed.joinCount * 3 : 0
        let joinIndices = lineJoinRound ? precomputed.joinCount * 3 : 0
        let capVerticesPerCap = 1 + Self.capUnitSemicircle.count
        let capIndicesPerCap = max(0, (Self.capUnitSemicircle.count - 1) * 3)
        let startCapCount = startCapRound && precomputed.firstValidSegmentIndex != nil ? 1 : 0
        let endCapCount = endCapRound && precomputed.lastValidSegmentIndex != nil ? 1 : 0
        let capCount = startCapCount + endCapCount

        vertices.reserveCapacity(segmentVertices + joinVertices + capCount * capVerticesPerCap)
        indices.reserveCapacity(segmentIndices + joinIndices + capCount * capIndicesPerCap)
    }

    private func appendSegments(precomputed: PrecomputedLine,
                                halfWidth: Float,
                                vertices: inout [SIMD2<Float>],
                                indices: inout [UInt32]) {
        for index in 0..<precomputed.segmentLengths.count {
            if precomputed.segmentLengths[index] <= Self.epsilon {
                continue
            }

            let start = precomputed.points[index]
            let end = precomputed.points[index + 1]
            let offset = precomputed.segmentNormals[index] * halfWidth

            let base = UInt32(vertices.count)
            vertices.append(start + offset)
            vertices.append(start - offset)
            vertices.append(end + offset)
            vertices.append(end - offset)

            indices.append(base)
            indices.append(base + 2)
            indices.append(base + 1)
            indices.append(base + 1)
            indices.append(base + 2)
            indices.append(base + 3)
        }
    }

    private func appendRoundJoins(precomputed: PrecomputedLine,
                                  halfWidth: Float,
                                  vertices: inout [SIMD2<Float>],
                                  indices: inout [UInt32]) {
        guard precomputed.points.count > 2 else { return }

        for index in 1..<(precomputed.points.count - 1) {
            if precomputed.segmentLengths[index - 1] <= Self.epsilon || precomputed.segmentLengths[index] <= Self.epsilon {
                continue
            }

            let dir0 = precomputed.segmentDirections[index - 1]
            let dir1 = precomputed.segmentDirections[index]
            let cross = dir0.x * dir1.y - dir0.y * dir1.x
            if abs(cross) <= Self.epsilon {
                continue
            }

            let center = precomputed.points[index]
            let left0 = precomputed.segmentNormals[index - 1]
            let left1 = precomputed.segmentNormals[index]
            let innerIsLeft = cross < 0
            let inner0 = center + (innerIsLeft ? left0 : -left0) * halfWidth
            let inner1 = center + (innerIsLeft ? left1 : -left1) * halfWidth

            let base = UInt32(vertices.count)
            vertices.append(center)
            vertices.append(inner0)
            vertices.append(inner1)

            indices.append(base)
            indices.append(base + 1)
            indices.append(base + 2)
        }
    }

    private func appendCap(center: SIMD2<Float>,
                           direction: SIMD2<Float>,
                           radius: Float,
                           flipDirection: Bool,
                           vertices: inout [SIMD2<Float>],
                           indices: inout [UInt32]) {
        let forward = flipDirection ? -direction : direction
        let right = SIMD2<Float>(-forward.y, forward.x)

        let base = UInt32(vertices.count)
        vertices.append(center)
        for point in Self.capUnitSemicircle {
            let transformed = center + (forward * point.x + right * point.y) * radius
            vertices.append(transformed)
        }

        for index in 1..<Self.capUnitSemicircle.count {
            indices.append(base)
            indices.append(base + UInt32(index))
            indices.append(base + UInt32(index + 1))
        }
    }

    private func toShortVector(_ value: SIMD2<Float>) -> SIMD2<Int16> {
        let x = Int16(clamping: Int(value.x.rounded()))
        let y = Int16(clamping: Int(value.y.rounded()))
        return SIMD2<Int16>(x, y)
    }

    private func clipToTile(polygon: TileMvtParser.ParsedPolygon,
                            tileExtent: Float) -> TileMvtParser.ParsedPolygon? {
        var generated = GeneratedPolygon()
        generated.vertices = polygon.vertices.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        generated.indices = polygon.indices
        return clipToTile(polygon: generated, tileExtent: tileExtent)
    }

    private func clipToTile(polygon: GeneratedPolygon,
                            tileExtent: Float) -> TileMvtParser.ParsedPolygon? {
        guard polygon.indices.isEmpty == false else { return nil }
        if polygon.vertices.allSatisfy({ isInsideTile($0, tileExtent: tileExtent) }) {
            return quantize(polygon: polygon)
        }

        let clipPolygon = Clipper.Polygon(points: [
            Clipper.Point(x: 0.0, y: 0.0),
            Clipper.Point(x: Double(tileExtent), y: 0.0),
            Clipper.Point(x: Double(tileExtent), y: Double(tileExtent)),
            Clipper.Point(x: 0.0, y: Double(tileExtent))
        ])

        var clippedVertices: [SIMD2<Int16>] = []
        var clippedIndices: [UInt32] = []

        for triangleStart in stride(from: 0, to: polygon.indices.count, by: 3) {
            guard triangleStart + 2 < polygon.indices.count else { break }

            let i0 = Int(polygon.indices[triangleStart])
            let i1 = Int(polygon.indices[triangleStart + 1])
            let i2 = Int(polygon.indices[triangleStart + 2])
            guard i0 < polygon.vertices.count, i1 < polygon.vertices.count, i2 < polygon.vertices.count else {
                continue
            }

            let triangle = [
                Clipper.Point(x: Double(polygon.vertices[i0].x), y: Double(polygon.vertices[i0].y)),
                Clipper.Point(x: Double(polygon.vertices[i1].x), y: Double(polygon.vertices[i1].y)),
                Clipper.Point(x: Double(polygon.vertices[i2].x), y: Double(polygon.vertices[i2].y))
            ]

            guard let clippedTriangle = clipper.sutherlandHodgmanClip(subjPoly: Clipper.Polygon(points: triangle),
                                                                      clipPoly: clipPolygon) else {
                continue
            }

            let clippedRing = sanitizeClippedRing(clippedTriangle.points.map {
                SIMD2<Float>(Float($0.x), Float($0.y))
            }, tileExtent: tileExtent)
            guard clippedRing.count >= 3 else {
                continue
            }

            let base = UInt32(clippedVertices.count)
            for point in clippedRing {
                clippedVertices.append(toShortVector(point))
            }

            let isClockwise = signedArea(of: clippedRing) < 0
            for index in 1..<(clippedRing.count - 1) {
                clippedIndices.append(base)
                if isClockwise {
                    clippedIndices.append(base + UInt32(index + 1))
                    clippedIndices.append(base + UInt32(index))
                } else {
                    clippedIndices.append(base + UInt32(index))
                    clippedIndices.append(base + UInt32(index + 1))
                }
            }
        }

        guard clippedIndices.isEmpty == false else { return nil }
        return TileMvtParser.ParsedPolygon(vertices: clippedVertices, indices: clippedIndices)
    }

    private func quantize(polygon: GeneratedPolygon) -> TileMvtParser.ParsedPolygon {
        TileMvtParser.ParsedPolygon(vertices: polygon.vertices.map(toShortVector),
                                    indices: polygon.indices)
    }

    private func sanitizeClippedRing(_ ring: [SIMD2<Float>], tileExtent: Float) -> [SIMD2<Float>] {
        guard ring.isEmpty == false else { return [] }

        var sanitized: [SIMD2<Float>] = []
        sanitized.reserveCapacity(ring.count)
        for point in ring {
            let clamped = clampToTile(point, tileExtent: tileExtent)
            if let last = sanitized.last, pointsEqual(last, clamped) {
                continue
            }
            sanitized.append(clamped)
        }

        if sanitized.count >= 2, let last = sanitized.last, let first = sanitized.first, pointsEqual(last, first) {
            sanitized.removeLast()
        }
        return sanitized
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

    private func isInsideTile(_ point: SIMD2<Float>, tileExtent: Float) -> Bool {
        point.x >= 0 && point.x <= tileExtent && point.y >= 0 && point.y <= tileExtent
    }

    private func clampToTile(_ point: SIMD2<Float>, tileExtent: Float) -> SIMD2<Float> {
        SIMD2<Float>(min(max(point.x, 0.0), tileExtent),
                     min(max(point.y, 0.0), tileExtent))
    }

    private func pointsEqual(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Bool {
        abs(lhs.x - rhs.x) <= Self.epsilon && abs(lhs.y - rhs.y) <= Self.epsilon
    }

    private func isStrictlyInsideTile(_ point: SIMD2<Float>, tileExtent: Float) -> Bool {
        point.x > 0.0 && point.x < tileExtent && point.y > 0.0 && point.y < tileExtent
    }
}
