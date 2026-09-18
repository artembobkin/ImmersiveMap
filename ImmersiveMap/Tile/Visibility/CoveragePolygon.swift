// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The frustum's footprint on the flat plane: the convex polygon the walk
/// tests every tile square against, built once per pose from the camera
/// matrix.
enum CoveragePolygonBuilder {
    static let planeIntersectionTolerance: Float = 1e-5



    static func make(cameraMatrix: matrix_float4x4?) -> CoveragePolygon? {
        guard let cameraMatrix else {
            return nil
        }

        let inverseCameraMatrix = simd_inverse(cameraMatrix)
        let frustumCorners = clipSpaceCorners.compactMap { unprojectClipSpacePoint($0, inverseCameraMatrix: inverseCameraMatrix) }
        guard frustumCorners.count == clipSpaceCorners.count else {
            return nil
        }

        var intersections: [SIMD2<Float>] = []
        intersections.reserveCapacity(frustumEdges.count * 2)

        for edge in frustumEdges {
            appendPlaneIntersections(from: frustumCorners[edge.start],
                                     to: frustumCorners[edge.end],
                                     intersections: &intersections)
        }

        let sortedVertices = sortVerticesClockwise(intersections)
        guard sortedVertices.count >= 3,
              abs(polygonSignedArea(sortedVertices)) > planeIntersectionTolerance else {
            return nil
        }

        return CoveragePolygon(vertices: sortedVertices)
    }

    private static func unprojectClipSpacePoint(_ point: SIMD3<Float>,
                                                inverseCameraMatrix: matrix_float4x4) -> SIMD3<Float>? {
        let homogenous = inverseCameraMatrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        guard homogenous.w.isFinite, abs(homogenous.w) > planeIntersectionTolerance else {
            return nil
        }

        let worldPoint = homogenous / homogenous.w
        guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else {
            return nil
        }

        return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
    }

    private static func appendPlaneIntersections(from start: SIMD3<Float>,
                                                 to end: SIMD3<Float>,
                                                 intersections: inout [SIMD2<Float>]) {
        appendIfPointLiesOnFlatPlane(start, intersections: &intersections)
        appendIfPointLiesOnFlatPlane(end, intersections: &intersections)

        let denominator = start.z - end.z
        guard abs(denominator) > planeIntersectionTolerance else {
            return
        }

        let t = start.z / denominator
        guard t >= -planeIntersectionTolerance, t <= 1 + planeIntersectionTolerance else {
            return
        }

        let clampedT = min(max(t, 0), 1)
        let point = start + (end - start) * clampedT
        guard abs(point.z) <= planeIntersectionTolerance else {
            return
        }

        appendUnique(SIMD2<Float>(point.x, point.y), intersections: &intersections)
    }

    private static func appendIfPointLiesOnFlatPlane(_ point: SIMD3<Float>,
                                                     intersections: inout [SIMD2<Float>]) {
        guard abs(point.z) <= planeIntersectionTolerance else {
            return
        }
        appendUnique(SIMD2<Float>(point.x, point.y), intersections: &intersections)
    }

    private static func appendUnique(_ point: SIMD2<Float>,
                                     intersections: inout [SIMD2<Float>]) {
        for existing in intersections {
            if simd_length_squared(existing - point) <= planeIntersectionTolerance * planeIntersectionTolerance {
                return
            }
        }
        intersections.append(point)
    }

    private static func sortVerticesClockwise(_ vertices: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard vertices.count >= 3 else {
            return []
        }

        let centroid = vertices.reduce(SIMD2<Float>.zero, +) / Float(vertices.count)
        return vertices.sorted { lhs, rhs in
            let lhsAngle = atan2(lhs.y - centroid.y, lhs.x - centroid.x)
            let rhsAngle = atan2(rhs.y - centroid.y, rhs.x - centroid.x)

            if abs(lhsAngle - rhsAngle) > planeIntersectionTolerance {
                return lhsAngle < rhsAngle
            }

            if abs(lhs.x - rhs.x) > planeIntersectionTolerance {
                return lhs.x < rhs.x
            }

            return lhs.y < rhs.y
        }
    }

    private static func polygonSignedArea(_ vertices: [SIMD2<Float>]) -> Float {
        guard vertices.count >= 3 else {
            return 0
        }

        var area: Float = 0
        for index in vertices.indices {
            let nextIndex = (index + 1) % vertices.count
            area += vertices[index].x * vertices[nextIndex].y - vertices[nextIndex].x * vertices[index].y
        }
        return area * 0.5
    }



    private static let clipSpaceCorners: [SIMD3<Float>] = [
        SIMD3<Float>(-1, -1, 0),
        SIMD3<Float>(1, -1, 0),
        SIMD3<Float>(1, 1, 0),
        SIMD3<Float>(-1, 1, 0),
        SIMD3<Float>(-1, -1, 1),
        SIMD3<Float>(1, -1, 1),
        SIMD3<Float>(1, 1, 1),
        SIMD3<Float>(-1, 1, 1)
    ]

    private static let frustumEdges: [(start: Int, end: Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7)
    ]
}

struct CoveragePolygon {
    let vertices: [SIMD2<Float>]
    let bounds: CoverageBounds

    /// Twice the signed area: the sign is the winding, which the clipping
    /// against the polygon's edges needs.
    var signedArea: Double {
        var area = 0.0
        for index in vertices.indices {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]
            area += Double(start.x) * Double(end.y) - Double(end.x) * Double(start.y)
        }
        return area
    }

    /// Whether the polygon meets an axis-aligned square of the plane: the
    /// polygon is convex, so its cut with the square's horizontal band is
    /// one x interval, and the square meets it exactly when that interval
    /// overlaps the square's own.
    func intersects(minX: Double, minY: Double, maxX: Double, maxY: Double) -> Bool {
        let tolerance = Double(CoveragePolygonBuilder.planeIntersectionTolerance)
        if Double(bounds.maxX) < minX - tolerance || Double(bounds.minX) > maxX + tolerance
            || Double(bounds.maxY) < minY - tolerance || Double(bounds.minY) > maxY + tolerance {
            return false
        }
        guard let xRange = horizontalSlabXRange(slabMinY: Float(minY - tolerance), slabMaxY: Float(maxY + tolerance)) else {
            return false
        }
        return Double(xRange.lowerBound) <= maxX + tolerance && Double(xRange.upperBound) >= minX - tolerance
    }

    /// The polygon cut by a line, keeping the side `inside` lies on
    /// (Sutherland-Hodgman against one half-plane). Nil when nothing of it
    /// is left, or too little to have an area.
    func clipped(keepingSideOf inside: SIMD2<Double>, ofLineFrom a: SIMD2<Double>, to b: SIMD2<Double>) -> CoveragePolygon? {
        let edge = b - a
        func side(_ point: SIMD2<Double>) -> Double {
            edge.x * (point.y - a.y) - edge.y * (point.x - a.x)
        }
        let insideSide = side(inside)
        guard abs(insideSide) > 1e-18 else { return self }
        let orientation = insideSide > 0 ? 1.0 : -1.0
        let points = vertices.map { SIMD2<Double>($0) }
        var clipped: [SIMD2<Float>] = []
        clipped.reserveCapacity(points.count + 2)
        for index in points.indices {
            let current = points[index]
            let previous = points[(index + points.count - 1) % points.count]
            let currentInside = orientation * side(current) >= 0
            let previousInside = orientation * side(previous) >= 0
            if currentInside {
                if previousInside == false {
                    clipped.append(SIMD2<Float>(Self.intersection(previous, current, a, b)))
                }
                clipped.append(SIMD2<Float>(current))
            } else if previousInside {
                clipped.append(SIMD2<Float>(Self.intersection(previous, current, a, b)))
            }
        }
        guard clipped.count >= 3 else { return nil }
        let polygon = CoveragePolygon(vertices: clipped)
        guard abs(polygon.signedArea) > Double(CoveragePolygonBuilder.planeIntersectionTolerance) else { return nil }
        return polygon
    }

    /// Where the segment from `a` to `b` crosses the line through `c` and `d`.
    static func intersection(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> SIMD2<Double> {
        let ab = b - a
        let cd = d - c
        let denominator = ab.x * cd.y - ab.y * cd.x
        guard abs(denominator) > 1e-18 else { return a }
        let t = ((c.x - a.x) * cd.y - (c.y - a.y) * cd.x) / denominator
        return a + ab * t
    }

    init(vertices: [SIMD2<Float>]) {
        self.vertices = vertices

        var minX = vertices[0].x
        var maxX = vertices[0].x
        var minY = vertices[0].y
        var maxY = vertices[0].y

        for vertex in vertices.dropFirst() {
            minX = min(minX, vertex.x)
            maxX = max(maxX, vertex.x)
            minY = min(minY, vertex.y)
            maxY = max(maxY, vertex.y)
        }

        bounds = CoverageBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    // The x interval of a convex polygon's intersection with a horizontal band.
    // Polygon ∩ band is a convex region; its x extrema are attained at polygon
    // vertices inside the band or at edge intersections with the band
    // boundaries, so no interior points need to be enumerated.
    func horizontalSlabXRange(slabMinY: Float, slabMaxY: Float) -> ClosedRange<Float>? {
        var lowestX = Float.greatestFiniteMagnitude
        var highestX = -Float.greatestFiniteMagnitude
        var hasIntersection = false

        for index in vertices.indices {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]

            if start.y >= slabMinY, start.y <= slabMaxY {
                lowestX = min(lowestX, start.x)
                highestX = max(highestX, start.x)
                hasIntersection = true
            }

            let deltaY = end.y - start.y
            guard abs(deltaY) > .ulpOfOne else {
                continue
            }
            let deltaX = end.x - start.x

            let tAtMinY = (slabMinY - start.y) / deltaY
            if tAtMinY >= 0, tAtMinY <= 1 {
                let x = start.x + deltaX * tAtMinY
                lowestX = min(lowestX, x)
                highestX = max(highestX, x)
                hasIntersection = true
            }

            let tAtMaxY = (slabMaxY - start.y) / deltaY
            if tAtMaxY >= 0, tAtMaxY <= 1 {
                let x = start.x + deltaX * tAtMaxY
                lowestX = min(lowestX, x)
                highestX = max(highestX, x)
                hasIntersection = true
            }
        }

        return hasIntersection ? lowestX...highestX : nil
    }
}

struct CoverageBounds {
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float
}
