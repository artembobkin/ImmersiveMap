// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Roof surface geometry for one extruded footprint, plus what the walls need
/// to meet the roof watertightly.
struct RoofGeometry {
    struct SurfaceVertex {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    let surfaceVertices: [SurfaceVertex]
    let surfaceIndices: [UInt32]
    /// The exterior ring with a vertex inserted wherever the gable ridge line
    /// crosses an edge, so a wall segment never spans a roof break line.
    let wallExteriorRing: [SIMD2<Float>]
    /// Wall-top height at a footprint point: the eaves for shapes with level
    /// eaves, the roof surface itself where walls rise into it (gable ends,
    /// skillion sides).
    let wallTop: (SIMD2<Float>) -> Float
}

/// Builds the roof surface for a non-flat `roof:shape`.
///
/// The roof frame (ridge line, slope direction, apex) is a property of the
/// footprint's own geometry: the ridge follows the long axis of the footprint's
/// minimum-area oriented bounding box, overridden by `roof:orientation` /
/// `roof:direction` where the data says so. It is invariant under rotation of
/// the tile grid. The mesh contains the vertices the shape needs (ridge
/// endpoints, apex, dome bands); footprints the builder cannot shape (holes
/// under anything but a skillion plane, degenerate rings) return nil and the
/// caller falls back to a flat lid at the full height.
enum RoofGeometryBuilder {
    private static let epsilon: Float = 0.001

    static func build(roof: RoofInfo,
                      exteriorRing: [SIMD2<Float>],
                      hasInteriorRings: Bool,
                      flatTriangulationVertices: [SIMD2<Float>],
                      flatTriangulationIndices: [UInt32],
                      baseHeight: Float,
                      topHeight: Float) -> RoofGeometry? {
        guard roof.shape != .flat, roof.shape != .unknown else { return nil }
        guard exteriorRing.count >= 3 else { return nil }

        let availableHeight = max(0, topHeight - baseHeight)
        let roofHeight = min(roof.height, availableHeight)
        guard roofHeight > 0 else { return nil }
        let roofBase = topHeight - roofHeight

        switch roof.shape {
        case .skillion:
            return skillion(roof: roof,
                            exteriorRing: exteriorRing,
                            flatTriangulationVertices: flatTriangulationVertices,
                            flatTriangulationIndices: flatTriangulationIndices,
                            roofBase: roofBase,
                            roofHeight: roofHeight)
        case .gabled:
            guard hasInteriorRings == false else { return nil }
            return gabled(roof: roof,
                          exteriorRing: exteriorRing,
                          roofBase: roofBase,
                          roofHeight: roofHeight)
        case .hipped:
            guard hasInteriorRings == false else { return nil }
            return hipped(roof: roof,
                          exteriorRing: exteriorRing,
                          roofBase: roofBase,
                          topHeight: topHeight)
        case .pyramid, .cone:
            guard hasInteriorRings == false else { return nil }
            return pointed(exteriorRing: exteriorRing,
                           smooth: roof.shape == .cone,
                           roofBase: roofBase,
                           topHeight: topHeight)
        case .dome:
            guard hasInteriorRings == false else { return nil }
            return dome(exteriorRing: exteriorRing,
                        roofBase: roofBase,
                        roofHeight: roofHeight)
        case .flat, .unknown:
            return nil
        }
    }

    // MARK: - Roof frame

    private struct RoofFrame {
        let ridgeDirection: SIMD2<Float>
        let slopeDirection: SIMD2<Float>
        let ridgeMin: Float
        let ridgeMax: Float
        let slopeMin: Float
        let slopeMax: Float

        var slopeCenter: Float { (slopeMin + slopeMax) * 0.5 }
        var slopeSpan: Float { (slopeMax - slopeMin) * 0.5 }
    }

    /// Compass azimuth in degrees to a unit vector in tile coordinates, where
    /// x grows east and y grows south: north is (0, -1), east is (1, 0).
    /// Web Mercator is conformal, so compass directions survive projection.
    private static func azimuthVector(degrees: Float) -> SIMD2<Float> {
        let radians = degrees * .pi / 180
        return SIMD2<Float>(sin(radians), -cos(radians))
    }

    private static func frame(for ring: [SIMD2<Float>], roof: RoofInfo) -> RoofFrame? {
        var ridgeDirection: SIMD2<Float>
        if let degrees = roof.directionDegrees {
            // roof:direction is the downslope azimuth; the ridge runs across it.
            let downslope = azimuthVector(degrees: degrees)
            ridgeDirection = SIMD2<Float>(-downslope.y, downslope.x)
        } else if let axes = orientedBoxAxes(of: ring) {
            ridgeDirection = roof.orientation == .across ? axes.short : axes.long
        } else {
            return nil
        }

        let slopeDirection = SIMD2<Float>(-ridgeDirection.y, ridgeDirection.x)
        var ridgeMin = simd_dot(ring[0], ridgeDirection)
        var ridgeMax = ridgeMin
        var slopeMin = simd_dot(ring[0], slopeDirection)
        var slopeMax = slopeMin
        for point in ring {
            let ridgeProjection = simd_dot(point, ridgeDirection)
            let slopeProjection = simd_dot(point, slopeDirection)
            ridgeMin = min(ridgeMin, ridgeProjection)
            ridgeMax = max(ridgeMax, ridgeProjection)
            slopeMin = min(slopeMin, slopeProjection)
            slopeMax = max(slopeMax, slopeProjection)
        }
        guard slopeMax - slopeMin > epsilon, ridgeMax - ridgeMin > epsilon else { return nil }
        return RoofFrame(ridgeDirection: ridgeDirection,
                         slopeDirection: slopeDirection,
                         ridgeMin: ridgeMin,
                         ridgeMax: ridgeMax,
                         slopeMin: slopeMin,
                         slopeMax: slopeMax)
    }

    /// Long and short axes of the minimum-area oriented bounding box of the
    /// ring's convex hull. Unlike the axis-aligned box, this is a property of
    /// the footprint itself and does not change when the tile grid rotates
    /// under the building.
    private static func orientedBoxAxes(of ring: [SIMD2<Float>]) -> (long: SIMD2<Float>, short: SIMD2<Float>)? {
        let hull = convexHull(of: ring)
        guard hull.count >= 3 else { return nil }

        var bestArea = Float.greatestFiniteMagnitude
        var bestAxes: (long: SIMD2<Float>, short: SIMD2<Float>)?
        for index in 0..<hull.count {
            let edge = hull[(index + 1) % hull.count] - hull[index]
            let length = simd_length(edge)
            guard length > epsilon else { continue }
            let axis = edge / length
            let perpendicular = SIMD2<Float>(-axis.y, axis.x)

            var minA = simd_dot(hull[0], axis)
            var maxA = minA
            var minP = simd_dot(hull[0], perpendicular)
            var maxP = minP
            for point in hull {
                let a = simd_dot(point, axis)
                let p = simd_dot(point, perpendicular)
                minA = min(minA, a)
                maxA = max(maxA, a)
                minP = min(minP, p)
                maxP = max(maxP, p)
            }
            let extentA = maxA - minA
            let extentP = maxP - minP
            let area = extentA * extentP
            if area < bestArea {
                bestArea = area
                bestAxes = extentA >= extentP ? (long: axis, short: perpendicular)
                                             : (long: perpendicular, short: axis)
            }
        }
        return bestAxes
    }

    /// Andrew's monotone chain. Returns fewer than 3 points for degenerate input.
    private static func convexHull(of points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Float>] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [SIMD2<Float>] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func areaCentroid(of ring: [SIMD2<Float>]) -> SIMD2<Float> {
        var area: Float = 0
        var centroid = SIMD2<Float>(0, 0)
        for index in 0..<ring.count {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            let crossValue = a.x * b.y - b.x * a.y
            area += crossValue
            centroid += (a + b) * crossValue
        }
        if abs(area) < epsilon {
            var sum = SIMD2<Float>(0, 0)
            for point in ring { sum += point }
            return sum / Float(ring.count)
        }
        return centroid / (3 * area)
    }

    // MARK: - Surface assembly

    /// Accumulates roof triangles in the emission convention the rest of the
    /// extrusion pipeline uses: index order chosen per triangle so its plan-view
    /// winding matches the flat-lid path, with the stored normal computed
    /// geometrically and pointing out of the roof (never down).
    private struct SurfaceMesh {
        var positions: [SIMD3<Float>] = []
        var normalSums: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var smooth: Bool

        init(smooth: Bool) {
            self.smooth = smooth
        }

        mutating func addVertex(_ position: SIMD3<Float>) -> UInt32 {
            positions.append(position)
            normalSums.append(SIMD3<Float>(0, 0, 0))
            return UInt32(positions.count - 1)
        }

        mutating func addTriangle(_ i0: UInt32, _ i1: UInt32, _ i2: UInt32) {
            let p0 = positions[Int(i0)]
            let p1 = positions[Int(i1)]
            let p2 = positions[Int(i2)]
            let planArea = (p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y)
            guard abs(planArea) > 1e-7 else { return }
            // The flat-lid path emits earcut triangles reversed, which lands on
            // a negative plan-view winding; every roof face must match it or
            // back culling shows one and hides the other.
            let ordered: (UInt32, UInt32, UInt32) = planArea < 0 ? (i0, i1, i2) : (i0, i2, i1)

            var faceNormal = simd_cross(positions[Int(ordered.1)] - positions[Int(ordered.0)],
                                        positions[Int(ordered.2)] - positions[Int(ordered.0)])
            if faceNormal.z < 0 {
                faceNormal = -faceNormal
            }
            let length = simd_length(faceNormal)
            guard length > 1e-7, faceNormal.x.isNaN == false else { return }
            faceNormal /= length

            if smooth {
                indices.append(ordered.0)
                indices.append(ordered.1)
                indices.append(ordered.2)
                normalSums[Int(ordered.0)] += faceNormal
                normalSums[Int(ordered.1)] += faceNormal
                normalSums[Int(ordered.2)] += faceNormal
            } else {
                let base = UInt32(positions.count)
                positions.append(positions[Int(ordered.0)])
                positions.append(positions[Int(ordered.1)])
                positions.append(positions[Int(ordered.2)])
                normalSums.append(faceNormal)
                normalSums.append(faceNormal)
                normalSums.append(faceNormal)
                indices.append(base)
                indices.append(base + 1)
                indices.append(base + 2)
            }
        }

        func finish() -> (vertices: [RoofGeometry.SurfaceVertex], indices: [UInt32])? {
            guard indices.isEmpty == false else { return nil }
            // Flat-shaded faces duplicate their corners, leaving the seed
            // vertices unreferenced; compact them away and remap the indices.
            var remap = Array(repeating: UInt32.max, count: positions.count)
            var vertices: [RoofGeometry.SurfaceVertex] = []
            vertices.reserveCapacity(indices.count)
            var remappedIndices: [UInt32] = []
            remappedIndices.reserveCapacity(indices.count)
            for index in indices {
                if remap[Int(index)] == .max {
                    let sum = normalSums[Int(index)]
                    let length = simd_length(sum)
                    let normal = length > 1e-7 ? sum / length : SIMD3<Float>(0, 0, 1)
                    remap[Int(index)] = UInt32(vertices.count)
                    vertices.append(RoofGeometry.SurfaceVertex(position: positions[Int(index)], normal: normal))
                }
                remappedIndices.append(remap[Int(index)])
            }
            return (vertices, remappedIndices)
        }
    }

    // MARK: - Skillion

    private static func skillion(roof: RoofInfo,
                                 exteriorRing: [SIMD2<Float>],
                                 flatTriangulationVertices: [SIMD2<Float>],
                                 flatTriangulationIndices: [UInt32],
                                 roofBase: Float,
                                 roofHeight: Float) -> RoofGeometry? {
        let downslope: SIMD2<Float>
        if let degrees = roof.directionDegrees {
            downslope = azimuthVector(degrees: degrees)
        } else if let axes = orientedBoxAxes(of: exteriorRing) {
            downslope = roof.orientation == .across ? axes.long : axes.short
        } else {
            return nil
        }

        var minProjection = simd_dot(exteriorRing[0], downslope)
        var maxProjection = minProjection
        for point in exteriorRing {
            let projection = simd_dot(point, downslope)
            minProjection = min(minProjection, projection)
            maxProjection = max(maxProjection, projection)
        }
        let range = maxProjection - minProjection
        guard range > epsilon else { return nil }

        func heightAt(_ point: SIMD2<Float>) -> Float {
            let projection = simd_dot(point, downslope)
            let factor = max(0, min(1, (maxProjection - projection) / range))
            return roofBase + roofHeight * factor
        }

        guard flatTriangulationIndices.count >= 3,
              flatTriangulationIndices.allSatisfy({ Int($0) < flatTriangulationVertices.count }) else {
            return nil
        }

        var mesh = SurfaceMesh(smooth: true)
        for vertex in flatTriangulationVertices {
            _ = mesh.addVertex(SIMD3<Float>(vertex.x, vertex.y, heightAt(vertex)))
        }
        var index = 0
        while index + 2 < flatTriangulationIndices.count {
            mesh.addTriangle(flatTriangulationIndices[index],
                             flatTriangulationIndices[index + 1],
                             flatTriangulationIndices[index + 2])
            index += 3
        }
        guard let surface = mesh.finish() else { return nil }
        return RoofGeometry(surfaceVertices: surface.vertices,
                            surfaceIndices: surface.indices,
                            wallExteriorRing: exteriorRing,
                            wallTop: heightAt)
    }

    // MARK: - Gabled

    private static func gabled(roof: RoofInfo,
                               exteriorRing: [SIMD2<Float>],
                               roofBase: Float,
                               roofHeight: Float) -> RoofGeometry? {
        guard let frame = frame(for: exteriorRing, roof: roof) else { return nil }
        let span = frame.slopeSpan
        guard span > epsilon else { return nil }
        let slopeDirection = frame.slopeDirection
        let slopeCenter = frame.slopeCenter

        func heightAt(_ point: SIMD2<Float>) -> Float {
            let distance = abs(simd_dot(point, slopeDirection) - slopeCenter)
            let factor = max(0, min(1, 1 - distance / span))
            return roofBase + roofHeight * factor
        }

        var mesh = SurfaceMesh(smooth: false)
        for keepNegative in [true, false] {
            let side = clipRing(exteriorRing,
                                direction: slopeDirection,
                                offset: slopeCenter,
                                keepNegative: keepNegative)
            let cleaned = removeConsecutiveDuplicates(side)
            guard cleaned.count >= 3 else { continue }

            var flattened: [Double] = []
            flattened.reserveCapacity(cleaned.count * 2)
            for point in cleaned {
                flattened.append(Double(point.x))
                flattened.append(Double(point.y))
            }
            let triangles = Earcut.tessellate(data: flattened)
            guard triangles.count >= 3 else { continue }

            var localIndices: [UInt32] = []
            localIndices.reserveCapacity(cleaned.count)
            for point in cleaned {
                localIndices.append(mesh.addVertex(SIMD3<Float>(point.x, point.y, heightAt(point))))
            }
            var index = 0
            while index + 2 < triangles.count {
                mesh.addTriangle(localIndices[Int(triangles[index])],
                                 localIndices[Int(triangles[index + 1])],
                                 localIndices[Int(triangles[index + 2])])
                index += 3
            }
        }
        guard let surface = mesh.finish() else { return nil }

        let enrichedRing = insertLineCrossings(into: exteriorRing,
                                               direction: slopeDirection,
                                               offset: slopeCenter)
        return RoofGeometry(surfaceVertices: surface.vertices,
                            surfaceIndices: surface.indices,
                            wallExteriorRing: enrichedRing,
                            wallTop: heightAt)
    }

    /// Sutherland-Hodgman clip of a ring against the half-plane on one side of
    /// the line `dot(p, direction) == offset`. On a concave ring the output can
    /// contain zero-width bridges along the clip line; they triangulate into
    /// degenerate slivers at ridge height, which `addTriangle` drops.
    private static func clipRing(_ ring: [SIMD2<Float>],
                                 direction: SIMD2<Float>,
                                 offset: Float,
                                 keepNegative: Bool) -> [SIMD2<Float>] {
        var output: [SIMD2<Float>] = []
        output.reserveCapacity(ring.count + 2)
        for index in 0..<ring.count {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            let sideA = simd_dot(a, direction) - offset
            let sideB = simd_dot(b, direction) - offset
            let keepA = keepNegative ? sideA <= 0 : sideA >= 0
            let keepB = keepNegative ? sideB <= 0 : sideB >= 0
            if keepA {
                output.append(a)
            }
            if keepA != keepB {
                let t = sideA / (sideA - sideB)
                output.append(a + (b - a) * t)
            }
        }
        return output
    }

    /// The wall ring with a vertex inserted at every strict crossing of the
    /// line `dot(p, direction) == offset`, using the same interpolation as
    /// `clipRing` so wall tops and roof edges land on identical points.
    private static func insertLineCrossings(into ring: [SIMD2<Float>],
                                            direction: SIMD2<Float>,
                                            offset: Float) -> [SIMD2<Float>] {
        var output: [SIMD2<Float>] = []
        output.reserveCapacity(ring.count + 2)
        for index in 0..<ring.count {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            output.append(a)
            let sideA = simd_dot(a, direction) - offset
            let sideB = simd_dot(b, direction) - offset
            if sideA * sideB < 0 {
                let t = sideA / (sideA - sideB)
                output.append(a + (b - a) * t)
            }
        }
        return output
    }

    private static func removeConsecutiveDuplicates(_ ring: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var output: [SIMD2<Float>] = []
        output.reserveCapacity(ring.count)
        for point in ring {
            if let last = output.last, simd_length(last - point) < epsilon {
                continue
            }
            output.append(point)
        }
        if output.count >= 2, let first = output.first, let last = output.last,
           simd_length(last - first) < epsilon {
            output.removeLast()
        }
        return output
    }

    // MARK: - Hipped

    private static func hipped(roof: RoofInfo,
                               exteriorRing: [SIMD2<Float>],
                               roofBase: Float,
                               topHeight: Float) -> RoofGeometry? {
        guard let frame = frame(for: exteriorRing, roof: roof) else { return nil }
        let span = frame.slopeSpan
        guard span > epsilon else { return nil }

        // Hip faces rise at the same plan-space slope as the sides, so the
        // ridge pulls in from each end by the slope span; a footprint too
        // short for that collapses the ridge to a point (a pyramid-like tent).
        var ridgeStart = frame.ridgeMin + span
        var ridgeEnd = frame.ridgeMax - span
        if ridgeStart > ridgeEnd {
            let middle = (frame.ridgeMin + frame.ridgeMax) * 0.5
            ridgeStart = middle
            ridgeEnd = middle
        }
        let slopeCenter = frame.slopeCenter

        func closestOnRidge(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let projection = simd_dot(point, frame.ridgeDirection)
            let clamped = max(ridgeStart, min(ridgeEnd, projection))
            return frame.ridgeDirection * clamped + frame.slopeDirection * slopeCenter
        }

        var mesh = SurfaceMesh(smooth: false)
        for index in 0..<exteriorRing.count {
            let p = exteriorRing[index]
            let q = exteriorRing[(index + 1) % exteriorRing.count]
            guard simd_length(q - p) > epsilon else { continue }
            let a = closestOnRidge(p)
            let b = closestOnRidge(q)

            let eaveP = mesh.addVertex(SIMD3<Float>(p.x, p.y, roofBase))
            let eaveQ = mesh.addVertex(SIMD3<Float>(q.x, q.y, roofBase))
            let ridgeQ = mesh.addVertex(SIMD3<Float>(b.x, b.y, topHeight))
            mesh.addTriangle(eaveP, eaveQ, ridgeQ)
            if simd_length(b - a) > epsilon {
                let ridgeP = mesh.addVertex(SIMD3<Float>(a.x, a.y, topHeight))
                mesh.addTriangle(eaveP, ridgeQ, ridgeP)
            }
        }
        guard let surface = mesh.finish() else { return nil }
        return RoofGeometry(surfaceVertices: surface.vertices,
                            surfaceIndices: surface.indices,
                            wallExteriorRing: exteriorRing,
                            wallTop: { _ in roofBase })
    }

    // MARK: - Pyramid and cone

    private static func pointed(exteriorRing: [SIMD2<Float>],
                                smooth: Bool,
                                roofBase: Float,
                                topHeight: Float) -> RoofGeometry? {
        let center = areaCentroid(of: exteriorRing)
        var mesh = SurfaceMesh(smooth: smooth)
        if smooth {
            var ringIndices: [UInt32] = []
            ringIndices.reserveCapacity(exteriorRing.count)
            for point in exteriorRing {
                ringIndices.append(mesh.addVertex(SIMD3<Float>(point.x, point.y, roofBase)))
            }
            let apex = mesh.addVertex(SIMD3<Float>(center.x, center.y, topHeight))
            for index in 0..<exteriorRing.count {
                mesh.addTriangle(ringIndices[index],
                                 ringIndices[(index + 1) % exteriorRing.count],
                                 apex)
            }
        } else {
            for index in 0..<exteriorRing.count {
                let p = exteriorRing[index]
                let q = exteriorRing[(index + 1) % exteriorRing.count]
                let i0 = mesh.addVertex(SIMD3<Float>(p.x, p.y, roofBase))
                let i1 = mesh.addVertex(SIMD3<Float>(q.x, q.y, roofBase))
                let i2 = mesh.addVertex(SIMD3<Float>(center.x, center.y, topHeight))
                mesh.addTriangle(i0, i1, i2)
            }
        }
        guard let surface = mesh.finish() else { return nil }
        return RoofGeometry(surfaceVertices: surface.vertices,
                            surfaceIndices: surface.indices,
                            wallExteriorRing: exteriorRing,
                            wallTop: { _ in roofBase })
    }

    // MARK: - Dome

    private static let domeBandCount = 5

    private static func dome(exteriorRing: [SIMD2<Float>],
                             roofBase: Float,
                             roofHeight: Float) -> RoofGeometry? {
        let center = areaCentroid(of: exteriorRing)
        let ringCount = exteriorRing.count
        var mesh = SurfaceMesh(smooth: true)

        var bands: [[UInt32]] = []
        bands.reserveCapacity(domeBandCount)
        for band in 0..<domeBandCount {
            let latitude = Float(band) / Float(domeBandCount) * (.pi / 2)
            let shrink = cos(latitude)
            let height = roofBase + roofHeight * sin(latitude)
            var indices: [UInt32] = []
            indices.reserveCapacity(ringCount)
            for point in exteriorRing {
                let position = center + (point - center) * shrink
                indices.append(mesh.addVertex(SIMD3<Float>(position.x, position.y, height)))
            }
            bands.append(indices)
        }
        let apex = mesh.addVertex(SIMD3<Float>(center.x, center.y, roofBase + roofHeight))

        for band in 0..<(domeBandCount - 1) {
            let lower = bands[band]
            let upper = bands[band + 1]
            for index in 0..<ringCount {
                let next = (index + 1) % ringCount
                mesh.addTriangle(lower[index], lower[next], upper[next])
                mesh.addTriangle(lower[index], upper[next], upper[index])
            }
        }
        let topBand = bands[domeBandCount - 1]
        for index in 0..<ringCount {
            mesh.addTriangle(topBand[index], topBand[(index + 1) % ringCount], apex)
        }

        guard let surface = mesh.finish() else { return nil }
        return RoofGeometry(surfaceVertices: surface.vertices,
                            surfaceIndices: surface.indices,
                            wallExteriorRing: exteriorRing,
                            wallTop: { _ in roofBase })
    }
}
