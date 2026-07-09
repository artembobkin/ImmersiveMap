// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

final class RoofHeightField {
    private let roofBase: Float
    private let roofHeight: Float
    private let shape: RoofShape
    private let center: SIMD2<Float>
    private let ridgeA: SIMD2<Float>
    private let ridgeB: SIMD2<Float>
    private let slopeDir: SIMD2<Float>
    private let slopeSpan: Float
    private let minProj: Float
    private let maxProj: Float
    private let maxRadius: Float

    init?(roof: RoofInfo,
          exteriorRing: [SIMD2<Float>],
          baseHeight: Float,
          topHeight: Float) {
        guard roof.shape != .flat, roof.shape != .unknown else { return nil }
        guard exteriorRing.isEmpty == false else { return nil }

        let availableHeight = max(0, topHeight - baseHeight)
        let clampedHeight = min(roof.height, availableHeight)
        guard clampedHeight > 0 else { return nil }

        self.roofHeight = clampedHeight
        self.roofBase = max(baseHeight, topHeight - clampedHeight)
        self.shape = roof.shape

        var minX = exteriorRing[0].x
        var maxX = exteriorRing[0].x
        var minY = exteriorRing[0].y
        var maxY = exteriorRing[0].y
        for point in exteriorRing {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let width = max(0.001, maxX - minX)
        let height = max(0.001, maxY - minY)
        let center = SIMD2<Float>((minX + maxX) * 0.5, (minY + maxY) * 0.5)
        self.center = center

        let ridgeAlongX = width >= height
        let ridgeDir = ridgeAlongX ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
        let slopeDir = ridgeAlongX ? SIMD2<Float>(0, 1) : SIMD2<Float>(1, 0)
        self.slopeDir = slopeDir
        self.slopeSpan = (ridgeAlongX ? height : width) * 0.5

        let longSide = max(width, height)
        let shortSide = max(0.001, min(width, height))
        let ridgeLength = max(0, longSide - shortSide)
        let ridgeHalf = ridgeLength * 0.5
        self.ridgeA = center - ridgeDir * ridgeHalf
        self.ridgeB = center + ridgeDir * ridgeHalf

        if roof.shape == .pyramid || roof.shape == .cone || roof.shape == .dome {
            var radius: Float = 0
            for point in exteriorRing {
                radius = max(radius, simd_length(point - center))
            }
            self.maxRadius = max(radius, 0.001)
        } else {
            self.maxRadius = 1.0
        }

        if roof.shape == .skillion {
            var minProj = simd_dot(exteriorRing[0], slopeDir)
            var maxProj = minProj
            for point in exteriorRing {
                let projection = simd_dot(point, slopeDir)
                minProj = min(minProj, projection)
                maxProj = max(maxProj, projection)
            }
            if abs(maxProj - minProj) < 0.001 {
                minProj -= 0.5
                maxProj += 0.5
            }
            self.minProj = minProj
            self.maxProj = maxProj
        } else {
            self.minProj = 0
            self.maxProj = 1
        }
    }

    func height(at point: SIMD2<Float>) -> Float {
        let factor: Float
        switch shape {
        case .gabled:
            let distance = abs(simd_dot(point - center, slopeDir))
            factor = clamp01(1 - distance / max(slopeSpan, 0.001))
        case .hipped:
            let distance = distanceToSegment(point, ridgeA, ridgeB)
            factor = clamp01(1 - distance / max(slopeSpan, 0.001))
        case .skillion:
            let proj = simd_dot(point, slopeDir)
            factor = clamp01((proj - minProj) / max(maxProj - minProj, 0.001))
        case .pyramid, .cone:
            let radius = simd_length(point - center)
            factor = clamp01(1 - radius / maxRadius)
        case .dome:
            let radius = simd_length(point - center)
            let ratio = min(1, radius / maxRadius)
            factor = sqrt(max(0, 1 - ratio * ratio))
        case .flat, .unknown:
            factor = 0
        }
        return roofBase + roofHeight * factor
    }

    private func clamp01(_ value: Float) -> Float {
        return max(0, min(1, value))
    }

    private func distanceToSegment(_ point: SIMD2<Float>,
                                   _ a: SIMD2<Float>,
                                   _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let abLen = simd_dot(ab, ab)
        if abLen < 0.0001 {
            return simd_length(point - a)
        }
        let t = clamp01(simd_dot(point - a, ab) / abLen)
        let projection = a + ab * t
        return simd_length(point - projection)
    }
}
