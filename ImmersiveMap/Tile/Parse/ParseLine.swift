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

        // Liang-Barsky edge distances packed in SIMD lanes so the per-segment
        // loop allocates nothing.
        let p = SIMD4<Float>(-delta.x, delta.x, -delta.y, delta.y)
        let q = SIMD4<Float>(
            start.x - bounds.minX,
            bounds.maxX - start.x,
            start.y - bounds.minY,
            bounds.maxY - start.y
        )

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
    /// Extra extrusion beyond the styled half-width, in tile units, giving the
    /// analytic antialiasing ramp room inside the geometry (the tile-unit
    /// counterpart of the route renderer's `kRouteFeatherPx`). Two units cover
    /// a one-pixel ramp down to a quarter of a screen pixel per tile unit; a
    /// tile minified further than that is already mip-filtered.
    static let featherTileUnits: Float = 2.0
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

    private struct GeneratedPolygon {
        var vertices: [SIMD2<Float>] = []
        /// Normalized signed centerline distances, lockstep with `vertices`:
        /// ±1 at the extruded rim, 0 on the centerline.
        var distances: [Float] = []
        /// Normalized longitudinal distances past the styled cut of a free
        /// butt end, lockstep with `vertices`: -1 at the feathered tip, 0 at
        /// the styled cut, saturated at 1 everywhere the end stays hard.
        var endDistances: [Float] = []
        var indices: [UInt32] = []
    }

    /// One clipped-ring vertex with its interpolated distance attributes.
    private struct AttributedPoint {
        var position: SIMD2<Float>
        var distance: Float
        var endDistance: Float
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

    /// `featherStart`/`featherEnd` mark an endpoint as a genuine free butt end
    /// (a dash cut, or a line simply ending), whose cut may be antialiased
    /// longitudinally. They must stay false for continuations that have to
    /// meet adjacent geometry flush (tile-seam cuts, road junctions); when the
    /// matching round cap is on, the cap's radial field wins and the flag is
    /// ignored.
    func parse(points: [SIMD2<Float>],
               width: Double,
               tileExtent: Float,
               startCapRound: Bool,
               endCapRound: Bool,
               lineJoinRound: Bool,
               featherStart: Bool = false,
               featherEnd: Bool = false,
               extendClippedStart: Bool = false,
               extendClippedEnd: Bool = false,
               clipPadding: Float = 0,
               clipGeometryToTileBounds: Bool = true) -> TileMvtParser.ParsedPolygon? {
        guard points.count >= 2, width > 0 else { return nil }

        // The geometry is extruded past the styled half-width so the shader's
        // one-pixel antialiasing ramp lies inside it; the styled edge is the
        // `edgeThreshold` isoline of the distance field emitted below.
        let halfWidth = Float(width * 0.5)
        let extrudedHalfWidth = halfWidth + Self.featherTileUnits
        let edgeThreshold = UInt8(clamping: Int((halfWidth / extrudedHalfWidth * 255.0).rounded()))
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
        polygon.distances.reserveCapacity(polygon.vertices.capacity)
        polygon.endDistances.reserveCapacity(polygon.vertices.capacity)

        appendSegments(precomputed: precomputed,
                       extrudedHalfWidth: extrudedHalfWidth,
                       featherStart: featherStart && startCapRound == false,
                       featherEnd: featherEnd && endCapRound == false,
                       polygon: &polygon)

        if lineJoinRound {
            appendRoundJoins(precomputed: precomputed,
                             extrudedHalfWidth: extrudedHalfWidth,
                             polygon: &polygon)
        }

        if startCapRound {
            if let startSegmentIndex = precomputed.firstValidSegmentIndex {
                appendCap(center: precomputed.points[0],
                          direction: precomputed.segmentDirections[startSegmentIndex],
                          radius: extrudedHalfWidth,
                          flipDirection: true,
                          polygon: &polygon)
            }
        }

        if endCapRound {
            if let endSegmentIndex = precomputed.lastValidSegmentIndex {
                appendCap(center: precomputed.points[points.count - 1],
                          direction: precomputed.segmentDirections[endSegmentIndex],
                          radius: extrudedHalfWidth,
                          flipDirection: false,
                          polygon: &polygon)
            }
        }

        return finalizePolygon(polygon,
                               tileExtent: tileExtent,
                               clipGeometryToTileBounds: clipGeometryToTileBounds,
                               edgeThreshold: edgeThreshold)
    }

    private func finalizePolygon(_ polygon: GeneratedPolygon,
                                 tileExtent: Float,
                                 clipGeometryToTileBounds: Bool,
                                 edgeThreshold: UInt8) -> TileMvtParser.ParsedPolygon? {
        if clipGeometryToTileBounds {
            return clipToTile(polygon: polygon, tileExtent: tileExtent, edgeThreshold: edgeThreshold)
        }
        return quantize(polygon: polygon, edgeThreshold: edgeThreshold)
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

    /// Emits each segment as a strip of full-width rows. A plain segment is
    /// two rows (the old single quad); a feathered free end adds a tip row
    /// one feather past the styled cut and a ring row one feather inside it,
    /// so the longitudinal field ramps -1...1 across the cut with the styled
    /// end on its zero isoline. A segment shorter than the feather pulls the
    /// ring to its midpoint, keeping the ramp's gradient exact rather than
    /// compressing it.
    private func appendSegments(precomputed: PrecomputedLine,
                                extrudedHalfWidth: Float,
                                featherStart: Bool,
                                featherEnd: Bool,
                                polygon: inout GeneratedPolygon) {
        let feather = Self.featherTileUnits
        for index in 0..<precomputed.segmentLengths.count {
            let segmentLength = precomputed.segmentLengths[index]
            if segmentLength <= Self.epsilon {
                continue
            }

            let start = precomputed.points[index]
            let end = precomputed.points[index + 1]
            let direction = precomputed.segmentDirections[index]
            let offset = precomputed.segmentNormals[index] * extrudedHalfWidth
            let featherThisStart = featherStart && index == precomputed.firstValidSegmentIndex
            let featherThisEnd = featherEnd && index == precomputed.lastValidSegmentIndex

            var rows: [(position: SIMD2<Float>, endDistance: Float)] = []
            if featherThisStart {
                let inset = min(feather, segmentLength * 0.5)
                rows.append((start - direction * feather, -1.0))
                rows.append((start + direction * inset, inset / feather))
            } else {
                rows.append((start, 1.0))
            }
            if featherThisEnd {
                let inset = min(feather, segmentLength * 0.5)
                rows.append((end - direction * inset, inset / feather))
                rows.append((end + direction * feather, -1.0))
            } else {
                rows.append((end, 1.0))
            }

            let base = UInt32(polygon.vertices.count)
            for row in rows {
                polygon.vertices.append(row.position + offset)
                polygon.vertices.append(row.position - offset)
                polygon.distances.append(1.0)
                polygon.distances.append(-1.0)
                polygon.endDistances.append(row.endDistance)
                polygon.endDistances.append(row.endDistance)
            }

            for rowIndex in 0..<(rows.count - 1) {
                let rowBase = base + UInt32(rowIndex * 2)
                polygon.indices.append(rowBase)
                polygon.indices.append(rowBase + 2)
                polygon.indices.append(rowBase + 1)
                polygon.indices.append(rowBase + 1)
                polygon.indices.append(rowBase + 2)
                polygon.indices.append(rowBase + 3)
            }
        }
    }

    private func appendRoundJoins(precomputed: PrecomputedLine,
                                  extrudedHalfWidth: Float,
                                  polygon: inout GeneratedPolygon) {
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
            let inner0 = center + (innerIsLeft ? left0 : -left0) * extrudedHalfWidth
            let inner1 = center + (innerIsLeft ? left1 : -left1) * extrudedHalfWidth

            let base = UInt32(polygon.vertices.count)
            polygon.vertices.append(center)
            polygon.vertices.append(inner0)
            polygon.vertices.append(inner1)
            polygon.distances.append(0.0)
            polygon.distances.append(1.0)
            polygon.distances.append(1.0)
            polygon.endDistances.append(1.0)
            polygon.endDistances.append(1.0)
            polygon.endDistances.append(1.0)

            polygon.indices.append(base)
            polygon.indices.append(base + 1)
            polygon.indices.append(base + 2)
        }
    }

    private func appendCap(center: SIMD2<Float>,
                           direction: SIMD2<Float>,
                           radius: Float,
                           flipDirection: Bool,
                           polygon: inout GeneratedPolygon) {
        let forward = flipDirection ? -direction : direction
        let right = SIMD2<Float>(-forward.y, forward.x)

        let base = UInt32(polygon.vertices.count)
        polygon.vertices.append(center)
        polygon.distances.append(0.0)
        polygon.endDistances.append(1.0)
        for point in Self.capUnitSemicircle {
            let transformed = center + (forward * point.x + right * point.y) * radius
            polygon.vertices.append(transformed)
            polygon.distances.append(1.0)
            polygon.endDistances.append(1.0)
        }

        for index in 1..<Self.capUnitSemicircle.count {
            polygon.indices.append(base)
            polygon.indices.append(base + UInt32(index))
            polygon.indices.append(base + UInt32(index + 1))
        }
    }

    private func toShortVector(_ value: SIMD2<Float>) -> SIMD2<Int16> {
        let x = Int16(clamping: Int(value.x.rounded()))
        let y = Int16(clamping: Int(value.y.rounded()))
        return SIMD2<Int16>(x, y)
    }

    private func clipToTile(polygon: GeneratedPolygon,
                            tileExtent: Float,
                            edgeThreshold: UInt8) -> TileMvtParser.ParsedPolygon? {
        guard polygon.indices.isEmpty == false else { return nil }
        if polygon.vertices.allSatisfy({ isInsideTile($0, tileExtent: tileExtent) }) {
            return quantize(polygon: polygon, edgeThreshold: edgeThreshold)
        }

        var clippedVertices: [SIMD2<Int16>] = []
        var clippedDistances: [Int8] = []
        var clippedEndDistances: [Int8] = []
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
                AttributedPoint(position: polygon.vertices[i0],
                                distance: polygon.distances[i0],
                                endDistance: polygon.endDistances[i0]),
                AttributedPoint(position: polygon.vertices[i1],
                                distance: polygon.distances[i1],
                                endDistance: polygon.endDistances[i1]),
                AttributedPoint(position: polygon.vertices[i2],
                                distance: polygon.distances[i2],
                                endDistance: polygon.endDistances[i2])
            ]

            let clippedRing = sanitizeClippedRing(clipRingToTile(triangle, tileExtent: tileExtent),
                                                  tileExtent: tileExtent)
            guard clippedRing.count >= 3 else {
                continue
            }

            let base = UInt32(clippedVertices.count)
            for point in clippedRing {
                clippedVertices.append(toShortVector(point.position))
                clippedDistances.append(Self.quantizeDistance(point.distance))
                clippedEndDistances.append(Self.quantizeDistance(point.endDistance))
            }

            let isClockwise = signedArea(of: clippedRing.map(\.position)) < 0
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
        return TileMvtParser.ParsedPolygon(vertices: clippedVertices,
                                           indices: clippedIndices,
                                           lineDistances: clippedDistances,
                                           lineEndDistances: clippedEndDistances,
                                           lineEdgeThreshold: edgeThreshold)
    }

    /// Sutherland-Hodgman against the tile square, interpolating the distance
    /// attribute at every intersection so the antialiasing field survives the
    /// clip. Each plane callback returns a signed inside distance (>= 0 keeps
    /// the point); when an edge crosses a plane the two signed distances have
    /// opposite signs, so their difference can never be zero.
    private func clipRingToTile(_ ring: [AttributedPoint], tileExtent: Float) -> [AttributedPoint] {
        func clip(_ points: [AttributedPoint],
                  planeDistance: (SIMD2<Float>) -> Float) -> [AttributedPoint] {
            guard points.count >= 3 else { return [] }
            var result: [AttributedPoint] = []
            result.reserveCapacity(points.count + 1)
            for index in 0..<points.count {
                let currentPoint = points[index]
                let previousPoint = points[(index + points.count - 1) % points.count]
                let currentDistance = planeDistance(currentPoint.position)
                let previousDistance = planeDistance(previousPoint.position)
                let currentInside = currentDistance >= 0
                if currentInside != (previousDistance >= 0) {
                    let t = previousDistance / (previousDistance - currentDistance)
                    result.append(AttributedPoint(
                        position: previousPoint.position + (currentPoint.position - previousPoint.position) * t,
                        distance: previousPoint.distance + (currentPoint.distance - previousPoint.distance) * t,
                        endDistance: previousPoint.endDistance + (currentPoint.endDistance - previousPoint.endDistance) * t))
                }
                if currentInside {
                    result.append(currentPoint)
                }
            }
            return result
        }

        var clipped = clip(ring) { $0.x }
        clipped = clip(clipped) { tileExtent - $0.x }
        clipped = clip(clipped) { $0.y }
        clipped = clip(clipped) { tileExtent - $0.y }
        return clipped
    }

    private func quantize(polygon: GeneratedPolygon, edgeThreshold: UInt8) -> TileMvtParser.ParsedPolygon {
        TileMvtParser.ParsedPolygon(vertices: polygon.vertices.map(toShortVector),
                                    indices: polygon.indices,
                                    lineDistances: polygon.distances.map(Self.quantizeDistance),
                                    lineEndDistances: polygon.endDistances.map(Self.quantizeDistance),
                                    lineEdgeThreshold: edgeThreshold)
    }

    private static func quantizeDistance(_ value: Float) -> Int8 {
        Int8(clamping: Int((value * Float(Int8.max)).rounded()))
    }

    private func sanitizeClippedRing(_ ring: [AttributedPoint], tileExtent: Float) -> [AttributedPoint] {
        guard ring.isEmpty == false else { return [] }

        var sanitized: [AttributedPoint] = []
        sanitized.reserveCapacity(ring.count)
        for point in ring {
            let clamped = clampToTile(point.position, tileExtent: tileExtent)
            if let last = sanitized.last, pointsEqual(last.position, clamped) {
                continue
            }
            sanitized.append(AttributedPoint(position: clamped,
                                             distance: point.distance,
                                             endDistance: point.endDistance))
        }

        if sanitized.count >= 2,
           let last = sanitized.last,
           let first = sanitized.first,
           pointsEqual(last.position, first.position) {
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
}
