// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

struct Bridge3DProfile {
    static let deckLift: Float = 28.0
    static let deckThickness: Float = 5.0
    static let roadSurfaceLiftAboveDeck: Float = 0.6

    static func roadSurfaceLift(for role: RoadPassRole) -> Float {
        switch role {
        case .casing:
            return roadSurfaceLiftAboveDeck
        case .fill:
            return roadSurfaceLiftAboveDeck + 0.2
        case .detail:
            return roadSurfaceLiftAboveDeck + 0.4
        case .overlay:
            return roadSurfaceLiftAboveDeck + 0.6
        case .shadow:
            return roadSurfaceLiftAboveDeck
        }
    }
}

final class BridgeHeightField {
    private let axisDirection: SIMD2<Float>
    private let minProjection: Float
    private let maxProjection: Float
    private let axisSpan: Float
    private let rampLength: Float
    private let hasPlateau: Bool

    init?(points: [SIMD2<Float>]) {
        guard points.count >= 2 else { return nil }

        let center = points.reduce(SIMD2<Float>.zero, +) / Float(points.count)
        var covarianceXX: Float = 0
        var covarianceXY: Float = 0
        var covarianceYY: Float = 0
        var minX = points[0].x
        var maxX = points[0].x
        var minY = points[0].y
        var maxY = points[0].y

        for point in points {
            let centered = point - center
            covarianceXX += centered.x * centered.x
            covarianceXY += centered.x * centered.y
            covarianceYY += centered.y * centered.y
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let width = maxX - minX
        let height = maxY - minY
        let trace = covarianceXX + covarianceYY
        let determinant = covarianceXX * covarianceYY - covarianceXY * covarianceXY
        let eigenTerm = sqrt(max(0, trace * trace * 0.25 - determinant))
        let dominantEigenvalue = trace * 0.5 + eigenTerm

        let axis: SIMD2<Float>
        if abs(covarianceXY) > 0.0001 {
            axis = SIMD2<Float>(dominantEigenvalue - covarianceYY, covarianceXY)
        } else {
            axis = width >= height ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
        }

        let axisLength = simd_length(axis)
        guard axisLength > 0.0001 else { return nil }
        let axisDirection = axis / axisLength
        let projections = points.map { simd_dot($0, axisDirection) }
        guard let minProjection = projections.min(),
              let maxProjection = projections.max() else {
            return nil
        }

        let axisSpan = maxProjection - minProjection
        guard axisSpan > 0.001 else { return nil }

        let initialRampLength = min(max(axisSpan * 0.18, 96.0), 320.0)
        if axisSpan >= 2.0 * initialRampLength + 64.0 {
            self.rampLength = initialRampLength
            self.hasPlateau = true
        } else {
            self.rampLength = max(32.0, min((axisSpan - 64.0) * 0.5, axisSpan * 0.5))
            self.hasPlateau = false
        }

        self.axisDirection = axisDirection
        self.minProjection = minProjection
        self.maxProjection = maxProjection
        self.axisSpan = axisSpan
    }

    func deckTopHeight(at point: SIMD2<Float>) -> Float {
        Bridge3DProfile.deckLift * heightFactor(at: point)
    }

    func deckBottomHeight(at point: SIMD2<Float>) -> Float {
        max(0.0, deckTopHeight(at: point) - Bridge3DProfile.deckThickness)
    }

    func roadSurfaceHeight(at point: SIMD2<Float>, role: RoadPassRole) -> Float {
        deckTopHeight(at: point) + Bridge3DProfile.roadSurfaceLift(for: role)
    }

    private func heightFactor(at point: SIMD2<Float>) -> Float {
        let projection = simd_dot(point, axisDirection)
        let clamped = min(max(projection, minProjection), maxProjection)

        if hasPlateau {
            let leftRampEnd = minProjection + rampLength
            let rightRampStart = maxProjection - rampLength
            if clamped <= leftRampEnd {
                return max(0, min(1, (clamped - minProjection) / max(rampLength, 0.001)))
            }
            if clamped >= rightRampStart {
                return max(0, min(1, (maxProjection - clamped) / max(rampLength, 0.001)))
            }
            return 1
        }

        let centerProjection = (minProjection + maxProjection) * 0.5
        let halfSpan = max(axisSpan * 0.5, 0.001)
        return max(0, min(1, 1 - abs(clamped - centerProjection) / halfSpan))
    }
}

extension TileMvtParser {
    struct BridgeDeckRecord {
        let styleKey: UInt8
        let style: FeatureStyle
        let exterior: [SIMD2<Float>]
        let interiors: [[SIMD2<Float>]]
        let polygon: ParsedPolygon
        let heightField: BridgeHeightField
        let areaEstimate: Float

        func contains(point: SIMD2<Float>) -> Bool {
            BridgeGeometry.contains(point: point, exterior: exterior, interiors: interiors)
        }
    }

    struct BridgeRoadSurfaceRecord {
        let styleKey: UInt8
        let style: FeatureStyle
        let polygon: ParsedPolygon
        let pathPoints: [SIMD2<Float>]
        let passRole: RoadPassRole
    }
}

enum BridgeGeometry {
    static func contains(point: SIMD2<Float>,
                         exterior: [SIMD2<Float>],
                         interiors: [[SIMD2<Float>]]) -> Bool {
        guard pointInRing(point, ring: exterior) else {
            return false
        }
        for interior in interiors where pointInRing(point, ring: interior) {
            return false
        }
        return true
    }

    static func centroid(of polygon: TileMvtParser.ParsedPolygon) -> SIMD2<Float> {
        guard polygon.vertices.isEmpty == false else { return .zero }
        let sum = polygon.vertices.reduce(SIMD2<Float>.zero) { partial, vertex in
            partial + SIMD2<Float>(Float(vertex.x), Float(vertex.y))
        }
        return sum / Float(polygon.vertices.count)
    }

    static func areaEstimate(of exterior: [SIMD2<Float>]) -> Float {
        guard exterior.isEmpty == false else { return 0 }
        var minX = exterior[0].x
        var maxX = exterior[0].x
        var minY = exterior[0].y
        var maxY = exterior[0].y
        for point in exterior {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return max(0, maxX - minX) * max(0, maxY - minY)
    }

    private static func pointInRing(_ point: SIMD2<Float>, ring: [SIMD2<Float>]) -> Bool {
        guard ring.count >= 3 else { return false }
        var isInside = false
        var previous = ring[ring.count - 1]

        for current in ring {
            let deltaY = previous.y - current.y
            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && abs(deltaY) > 0.0001
                && (point.x < (previous.x - current.x) * (point.y - current.y) / deltaY + current.x)
            if intersects {
                isInside.toggle()
            }
            previous = current
        }

        return isInside
    }
}
