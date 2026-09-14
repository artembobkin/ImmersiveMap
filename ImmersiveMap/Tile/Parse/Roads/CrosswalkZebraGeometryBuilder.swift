// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct CrosswalkZebraGeometryBuilder {
    private static let epsilon: Float = 0.0001

    /// Input polyline is TILE space (y down); the first line of the body is
    /// the decoration path's one named entry into render space, and the
    /// output quads are quantized render-space vertices.
    func buildPolygons(points: [SIMD2<Float>],
                       zoneWidth: Float,
                       zebra: ZebraCrossingDecoration = ZebraCrossingDecoration()) -> [ParsedPolygon] {
        guard points.count >= 2 else {
            return []
        }

        let renderPoints = TileCoordinateSpace.renderPoints(points)

        let crossingLength = polylineLength(points: renderPoints)
        guard crossingLength >= zebra.minimumCrossingLength else {
            return []
        }

        let direction = normalizedDirection(from: renderPoints)
        guard simd_length(direction) > Self.epsilon else {
            return []
        }

        let usableZoneWidth = max(zoneWidth, zebra.minimumStripeWidth)
        let stripeStep = max(zebra.minimumStripeStep, usableZoneWidth / zebra.stripeStepDivisor)
        let stripeWidth = max(zebra.minimumStripeWidth, stripeStep * zebra.stripeFillFactor)
        let halfZoneWidth = usableZoneWidth * 0.5
        let center = point(atDistance: crossingLength * 0.5, points: renderPoints)
        let halfLength = max(zebra.minimumCrossingLength * 0.5,
                             crossingLength * (0.5 - zebra.endInsetFactor))
        let normal = SIMD2<Float>(-direction.y, direction.x)

        var polygons: [ParsedPolygon] = []
        polygons.reserveCapacity(max(1, Int(ceil(crossingLength / stripeStep))))

        var stripeStart = -halfLength
        while stripeStart < halfLength - Self.epsilon {
            let stripeEnd = min(stripeStart + stripeWidth, halfLength)
            let stripeHalfWidth = max((stripeEnd - stripeStart) * 0.5, zebra.minimumStripeWidth * 0.5)
            let stripeOffset = (stripeStart + stripeEnd) * 0.5
            let stripeCenter = center + direction * stripeOffset

            let along = direction * stripeHalfWidth
            let across = normal * halfZoneWidth

            let topLeft = stripeCenter - along - across
            let bottomLeft = stripeCenter - along + across
            let bottomRight = stripeCenter + along + across
            let topRight = stripeCenter + along - across

            polygons.append(
                ParsedPolygon(
                    vertices: [
                        TileCoordinateSpace.quantized(topLeft),
                        TileCoordinateSpace.quantized(bottomLeft),
                        TileCoordinateSpace.quantized(bottomRight),
                        TileCoordinateSpace.quantized(topRight)
                    ],
                    // Counter-clockwise in render space, like every tile
                    // triangle: the ring above runs clockwise.
                    indices: [0, 2, 1, 0, 3, 2]
                )
            )

            stripeStart += stripeStep
        }

        return polygons
    }

    private func polylineLength(points: [SIMD2<Float>]) -> Float {
        guard points.count >= 2 else {
            return 0.0
        }

        var total: Float = 0.0
        for index in 1..<points.count {
            total += simd_length(points[index] - points[index - 1])
        }
        return total
    }

    private func normalizedDirection(from points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard let start = points.first, let end = points.last else {
            return .zero
        }

        let delta = end - start
        let length = simd_length(delta)
        guard length > Self.epsilon else {
            return .zero
        }
        return delta / length
    }

    private func point(atDistance distance: Float, points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard let first = points.first else {
            return .zero
        }
        guard points.count >= 2 else {
            return first
        }

        var traversed: Float = 0.0
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let delta = end - start
            let segmentLength = simd_length(delta)
            guard segmentLength > Self.epsilon else {
                continue
            }

            let nextTraversed = traversed + segmentLength
            if distance <= nextTraversed {
                let t = (distance - traversed) / segmentLength
                return start + delta * t
            }
            traversed = nextTraversed
        }

        return points.last ?? first
    }
}
