// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Stamps the letter A along a dedicated bus lane, the way the asphalt
/// carries it: a large white letter every stretch of lane, feet toward the
/// driver, so the lane reads as a bus lane without recoloring its surface.
///
/// The input polyline is the lane's axis in tile space (y down), oriented
/// WITH the direction of travel: the tiles reverse a contraflow lane before
/// shipping it. Each letter is three strokes (two legs and the crossbar)
/// emitted as quads, like the zebra's stripes and the arrows.
struct BusLaneLetterGeometryBuilder {
    /// The letter on the ground is about as tall as the lane is wide.
    private static let letterHeightMetres: Float = 2.6
    /// Half the spread of the legs at the feet.
    private static let letterHalfWidthMetres: Float = 0.9
    /// Road symbols are painted with the thick stroke.
    private static let strokeMetres: Float = 0.4
    /// Where the crossbar sits, as a fraction of the height from the feet.
    private static let crossbarFraction: Float = 0.32
    /// One letter per this stretch of lane; short stubs get a single letter
    /// in the middle, and a stub shorter than two letters gets none.
    private static let repeatStepMetres: Float = 30.0
    private static let endInsetMetres: Float = 3.0

    func buildPolygons(points: [SIMD2<Float>],
                       unitsPerMetre: Float) -> [TileMvtParser.ParsedPolygon] {
        guard points.count >= 2, unitsPerMetre > 0 else { return [] }
        let renderPoints = TileCoordinateSpace.renderPoints(points)
        let totalLength = Self.polylineLength(renderPoints)
        let height = Self.letterHeightMetres * unitsPerMetre
        let endInset = Self.endInsetMetres * unitsPerMetre
        guard totalLength >= height * 2 + endInset else { return [] }

        let step = Self.repeatStepMetres * unitsPerMetre
        let usable = totalLength - endInset * 2
        let placements: [Float]
        if usable <= step {
            placements = [totalLength * 0.5]
        } else {
            let count = Int(usable / step) + 1
            let actualStep = usable / Float(max(1, count - 1))
            placements = (0..<count).map { endInset + Float($0) * actualStep }
        }

        var polygons: [TileMvtParser.ParsedPolygon] = []
        polygons.reserveCapacity(placements.count * 3)
        for distance in placements {
            guard let sample = Self.sample(atDistance: distance, points: renderPoints) else { continue }
            polygons.append(contentsOf: Self.makeLetter(center: sample.position,
                                                        up: sample.tangent,
                                                        unitsPerMetre: unitsPerMetre))
        }
        return polygons
    }

    /// The letter in the frame (up = direction of travel, so the feet face
    /// the driver approaching it): two legs from the feet to the apex and
    /// the crossbar between them.
    private static func makeLetter(center: SIMD2<Float>,
                                   up: SIMD2<Float>,
                                   unitsPerMetre: Float) -> [TileMvtParser.ParsedPolygon] {
        let side = SIMD2<Float>(-up.y, up.x)
        let halfHeight = letterHeightMetres * unitsPerMetre * 0.5
        let halfWidth = letterHalfWidthMetres * unitsPerMetre
        let stroke = strokeMetres * unitsPerMetre
        let apex = center + up * halfHeight
        let leftFoot = center - up * halfHeight + side * halfWidth
        let rightFoot = center - up * halfHeight - side * halfWidth
        let leftBar = leftFoot + (apex - leftFoot) * crossbarFraction
        let rightBar = rightFoot + (apex - rightFoot) * crossbarFraction
        return [
            strokeQuad(from: leftFoot, to: apex, stroke: stroke),
            strokeQuad(from: rightFoot, to: apex, stroke: stroke),
            strokeQuad(from: leftBar, to: rightBar, stroke: stroke)
        ].compactMap { $0 }
    }

    private static func strokeQuad(from a: SIMD2<Float>,
                                   to b: SIMD2<Float>,
                                   stroke: Float) -> TileMvtParser.ParsedPolygon? {
        let length = simd_distance(a, b)
        guard length > 1e-3 else { return nil }
        let direction = (b - a) / length
        let normal = SIMD2<Float>(-direction.y, direction.x) * (stroke * 0.5)
        return TileMvtParser.ParsedPolygon(
            vertices: [TileCoordinateSpace.quantized(a + normal), TileCoordinateSpace.quantized(a - normal),
                       TileCoordinateSpace.quantized(b - normal), TileCoordinateSpace.quantized(b + normal)],
            indices: [0, 1, 2, 0, 2, 3]
        )
    }

    private static func polylineLength(_ points: [SIMD2<Float>]) -> Float {
        var total: Float = 0
        for index in 1..<points.count {
            total += simd_distance(points[index - 1], points[index])
        }
        return total
    }

    private static func sample(atDistance distance: Float,
                               points: [SIMD2<Float>]) -> (position: SIMD2<Float>, tangent: SIMD2<Float>)? {
        var remaining = distance
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let segment = simd_distance(a, b)
            guard segment > 1e-6 else { continue }
            if remaining <= segment {
                let t = remaining / segment
                return (a + (b - a) * t, (b - a) / segment)
            }
            remaining -= segment
        }
        return nil
    }
}
