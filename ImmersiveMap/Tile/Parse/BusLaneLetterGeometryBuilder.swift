// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Stamps the letter A along a dedicated bus lane, the way the asphalt
/// carries it: a large white letter every stretch of lane, feet toward the
/// driver, so the lane reads as a bus lane without recoloring its surface.
///
/// The input polyline is the lane's axis in tile space (y down), oriented
/// WITH the direction of travel: the tiles reverse a contraflow lane before
/// shipping it. Each letter is three quads (two legs sharing a mitered apex
/// edge, and the crossbar between their centrelines), emitted like the
/// zebra's stripes and the arrows.
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
    ///
    /// The legs are the two halves of one mitered lambda. They share the
    /// apex edge (the intersections of their outer and of their inner
    /// stroke edges, both on the letter's axis), so the apex is a single
    /// sharp point instead of two butt caps crossing; the feet are cut flat
    /// along the baseline, and the crossbar runs from one leg's centreline
    /// to the other's, so rounding to the vertex grid can leave neither a
    /// gap nor a stray corner. Identical floats quantize identically, which
    /// is what keeps the shared apex edge seamless in Int16.
    private static func makeLetter(center: SIMD2<Float>,
                                   up: SIMD2<Float>,
                                   unitsPerMetre: Float) -> [TileMvtParser.ParsedPolygon] {
        let side = SIMD2<Float>(-up.y, up.x)
        let halfHeight = letterHeightMetres * unitsPerMetre * 0.5
        let halfWidth = letterHalfWidthMetres * unitsPerMetre
        let halfStroke = strokeMetres * unitsPerMetre * 0.5
        let apex = center + up * halfHeight
        let baseCenter = center - up * halfHeight
        let leftFoot = baseCenter + side * halfWidth
        let rightFoot = baseCenter - side * halfWidth

        // The apex edge, shared by both leg quads: where the outer (and the
        // inner) stroke edges of the two legs meet, on the letter's axis.
        let legLength = simd_distance(leftFoot, apex)
        guard legLength > 1e-3 else { return [] }
        let sineOfHalfSpread = halfWidth / legLength
        guard sineOfHalfSpread > 1e-3 else { return [] }
        let apexReach = halfStroke / sineOfHalfSpread
        let apexOuter = apex + up * apexReach
        let apexInner = apex - up * apexReach

        // Feet cut flat along the baseline: each leg edge, offset half a
        // stroke to its side, intersected with the line through the feet.
        func legQuad(foot: SIMD2<Float>) -> TileMvtParser.ParsedPolygon? {
            let direction = (apex - foot) / legLength
            let normal = SIMD2<Float>(-direction.y, direction.x)
            guard let baseA = Self.intersect(point: foot + normal * halfStroke, direction: direction,
                                             withPoint: baseCenter, direction: side),
                  let baseB = Self.intersect(point: foot - normal * halfStroke, direction: direction,
                                             withPoint: baseCenter, direction: side) else {
                return nil
            }
            return TileMvtParser.ParsedPolygon(
                vertices: [TileCoordinateSpace.quantized(baseA), TileCoordinateSpace.quantized(apexOuter),
                           TileCoordinateSpace.quantized(apexInner), TileCoordinateSpace.quantized(baseB)],
                indices: [0, 1, 2, 0, 2, 3]
            )
        }

        // The crossbar: a band of the stroke's thickness at the crossbar
        // height, ending ON the legs' centrelines. The half-stroke it sinks
        // into each leg is one colour under one alpha, invisible; a bar cut
        // at the inner edges could round into a one-unit gap instead.
        let leftBar = leftFoot + (apex - leftFoot) * crossbarFraction
        let rightBar = rightFoot + (apex - rightFoot) * crossbarFraction
        let barLift = up * halfStroke
        let crossbar = TileMvtParser.ParsedPolygon(
            vertices: [TileCoordinateSpace.quantized(leftBar + barLift), TileCoordinateSpace.quantized(rightBar + barLift),
                       TileCoordinateSpace.quantized(rightBar - barLift), TileCoordinateSpace.quantized(leftBar - barLift)],
            indices: [0, 1, 2, 0, 2, 3]
        )
        return [legQuad(foot: leftFoot), legQuad(foot: rightFoot), crossbar].compactMap { $0 }
    }

    /// Where the line through `point` along `direction` crosses the line
    /// through `withPoint` along its direction, or nil for parallels.
    private static func intersect(point a: SIMD2<Float>, direction u: SIMD2<Float>,
                                  withPoint b: SIMD2<Float>, direction v: SIMD2<Float>) -> SIMD2<Float>? {
        let denominator = u.x * v.y - u.y * v.x
        guard abs(denominator) > 1e-6 else { return nil }
        let t = ((b.x - a.x) * v.y - (b.y - a.y) * v.x) / denominator
        return a + u * t
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
