// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Turns one resolved building candidate into its mesh: a flat lid at the
/// top height and a wall per footprint edge, in render space with every
/// normal facing out of the building material.
enum BuildingExtrusionMeshBuilder {
    static func build(
        clippedExterior: [SIMD2<Float>],
        clippedInteriors: [[SIMD2<Float>]],
        roof: ParsedPolygon,
        baseHeight: Float,
        topHeight: Float,
        tileExtent: Float
    ) -> ParsedExtrudedMesh? {
        guard topHeight > baseHeight else { return nil }

        var vertices: [ParsedExtrudedVertex] = []
        var indices: [UInt32] = []
        var nextLocalSurfaceID: UInt32 = 1

        let epsilon: Float = 0.001
        let extent = tileExtent
        func isOnBoundary(_ point: SIMD2<Float>) -> Bool {
            abs(point.x) <= epsilon ||
            abs(point.y) <= epsilon ||
            abs(point.x - extent) <= epsilon ||
            abs(point.y - extent) <= epsilon
        }

        func isBoundaryEdge(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
            guard isOnBoundary(a), isOnBoundary(b) else { return false }
            return abs(a.x - b.x) <= epsilon || abs(a.y - b.y) <= epsilon
        }

        func ringArea(_ ring: [SIMD2<Float>]) -> Float {
            guard ring.count >= 3 else { return 0 }
            var sum: Float = 0
            for i in 0..<ring.count {
                let j = (i + 1) % ring.count
                sum += ring[i].x * ring[j].y - ring[j].x * ring[i].y
            }
            return sum * 0.5
        }

        func sanitizeRing(_ ring: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var ringPoints = ring
            if let last = ringPoints.last, let first = ringPoints.first, last == first {
                ringPoints.removeLast()
            }

            var filteredRing: [SIMD2<Float>] = []
            filteredRing.reserveCapacity(ringPoints.count)
            for point in ringPoints {
                if filteredRing.last == point {
                    continue
                }
                if filteredRing.count >= 2, filteredRing[filteredRing.count - 2] == point {
                    filteredRing.removeLast()
                    continue
                }
                filteredRing.append(point)
            }
            if filteredRing.count >= 2, let last = filteredRing.last, let first = filteredRing.first, last == first {
                filteredRing.removeLast()
            }
            return filteredRing
        }

        func ensureWinding(_ ring: [SIMD2<Float>], clockwise: Bool) -> [SIMD2<Float>] {
            var ringPoints = ring
            let area = ringArea(ringPoints)
            let isClockwise = area < 0
            if isClockwise != clockwise {
                ringPoints.reverse()
            }
            return ringPoints
        }

        let sanitizedExterior = sanitizeRing(clippedExterior)
        let roofOffset = UInt32(vertices.count)
        if roof.indices.count >= 3 {
            // The flat lid at the full height.
            let roofSurfaceID = nextLocalSurfaceID
            nextLocalSurfaceID &+= 1
            let roofNormal = SIMD3<Float>(0, 0, 1)
            vertices.append(contentsOf: roof.vertices.map {
                ParsedExtrudedVertex(
                    position: SIMD3<Float>(Float($0.x), Float($0.y), topHeight),
                    normal: roofNormal,
                    surfaceID: roofSurfaceID
                )
            })
            for i in stride(from: 0, to: roof.indices.count, by: 3) {
                if i + 2 >= roof.indices.count { break }
                let i0 = roof.indices[i] + roofOffset
                let i1 = roof.indices[i + 1] + roofOffset
                let i2 = roof.indices[i + 2] + roofOffset
                indices.append(i0)
                indices.append(i2)
                indices.append(i1)
            }
        }

        func appendWalls(for ring: [SIMD2<Float>], clockwise: Bool, isSanitized: Bool = false) {
            var ringPoints = isSanitized ? ring : sanitizeRing(ring)
            guard ringPoints.count >= 2 else { return }
            ringPoints = ensureWinding(ringPoints, clockwise: clockwise)

            for i in 0..<ringPoints.count {
                let next = (i + 1) % ringPoints.count
                let p0 = ringPoints[i]
                let p1 = ringPoints[next]
                if p0 == p1 { continue }
                if isBoundaryEdge(p0, p1) { continue }

                let v0 = SIMD3<Float>(p0.x, p0.y, baseHeight)
                let v1 = SIMD3<Float>(p1.x, p1.y, baseHeight)
                let v2 = SIMD3<Float>(p1.x, p1.y, topHeight)
                let v3 = SIMD3<Float>(p0.x, p0.y, topHeight)
                // Argument order makes every wall normal face out of the
                // building material: away from an exterior ring's interior,
                // into a hole ring's cavity (exterior rings are wound CW
                // here, holes CCW). The shading contract depends on this:
                // the shadow shader treats an away-facing normal as
                // geometric self-shadow.
                let wallNormal = simd_normalize(simd_cross(v2 - v0, v1 - v0))
                if wallNormal.x.isNaN || wallNormal.y.isNaN || wallNormal.z.isNaN {
                    continue
                }

                let wallSurfaceID = nextLocalSurfaceID
                nextLocalSurfaceID &+= 1
                let startIndex = UInt32(vertices.count)
                vertices.append(ParsedExtrudedVertex(position: v0, normal: wallNormal, surfaceID: wallSurfaceID))
                vertices.append(ParsedExtrudedVertex(position: v1, normal: wallNormal, surfaceID: wallSurfaceID))
                vertices.append(ParsedExtrudedVertex(position: v2, normal: wallNormal, surfaceID: wallSurfaceID))
                vertices.append(ParsedExtrudedVertex(position: v3, normal: wallNormal, surfaceID: wallSurfaceID))

                indices.append(contentsOf: [
                    startIndex, startIndex + 1, startIndex + 2,
                    startIndex, startIndex + 2, startIndex + 3
                ])
            }
        }

        // Exterior: CW so walls are front-facing with back culling in current tile space.
        appendWalls(for: sanitizedExterior, clockwise: true, isSanitized: true)
        for interior in clippedInteriors {
            // Interior (hole): opposite winding
            appendWalls(for: interior, clockwise: false)
        }

        return indices.isEmpty ? nil : ParsedExtrudedMesh(vertices: vertices, indices: indices)
    }
}
