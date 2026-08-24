// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The yellow zigzag along the kerb at a public transport stop: the "bus
/// stop" road marking, a sawtooth line running the length of the stop.
///
/// The tiles ship the zigzag's axis (a slice of the carriageway edge around
/// the stop, `marking=bus_stop_zigzag`); the builder folds it into a sawtooth
/// polyline and emits each tooth segment as a quad, like the letter and the
/// zebra. Input is tile space (y down).
struct BusStopZigzagGeometryBuilder {
    /// One full tooth (out and back) per this stretch of axis.
    private static let toothPeriodMetres: Float = 2.4
    /// Half the sawtooth's sweep across the axis.
    private static let amplitudeMetres: Float = 0.6
    /// The stroke of the paint.
    private static let strokeMetres: Float = 0.35

    func buildPolygons(points: [SIMD2<Float>],
                       unitsPerMetre: Float) -> [TileMvtParser.ParsedPolygon] {
        guard points.count >= 2, unitsPerMetre > 0 else { return [] }
        let renderPoints = TileCoordinateSpace.renderPoints(points)
        let total = Self.polylineLength(renderPoints)
        let halfPeriod = Self.toothPeriodMetres * unitsPerMetre * 0.5
        guard total >= halfPeriod * 2 else { return [] }

        // Sawtooth vertices every half period, alternating across the axis;
        // the first and the last sit on the axis so the figure closes clean.
        let steps = Int(total / halfPeriod)
        var teeth: [SIMD2<Float>] = []
        teeth.reserveCapacity(steps + 2)
        let amplitude = Self.amplitudeMetres * unitsPerMetre
        for step in 0...steps {
            let distance = Float(step) * halfPeriod
            guard let sample = Self.sample(atDistance: min(distance, total), points: renderPoints) else { continue }
            let side = SIMD2<Float>(-sample.tangent.y, sample.tangent.x)
            let sway: Float = step == 0 || step == steps ? 0 : (step.isMultiple(of: 2) ? -amplitude : amplitude)
            teeth.append(sample.position + side * sway)
        }
        guard teeth.count >= 2 else { return [] }

        let stroke = Self.strokeMetres * unitsPerMetre
        var polygons: [TileMvtParser.ParsedPolygon] = []
        polygons.reserveCapacity(teeth.count - 1)
        for index in 1..<teeth.count {
            if let quad = Self.strokeQuad(from: teeth[index - 1], to: teeth[index], stroke: stroke) {
                polygons.append(quad)
            }
        }
        return polygons
    }

    private static func strokeQuad(from a: SIMD2<Float>,
                                   to b: SIMD2<Float>,
                                   stroke: Float) -> TileMvtParser.ParsedPolygon? {
        let length = simd_distance(a, b)
        guard length > 1e-3 else { return nil }
        let direction = (b - a) / length
        let normal = SIMD2<Float>(-direction.y, direction.x) * (stroke * 0.5)
        // The teeth overlap at their shared vertices by half a stroke; one
        // colour, so the overlap is invisible and the joint never gaps.
        let along = direction * (stroke * 0.5)
        return TileMvtParser.ParsedPolygon(
            vertices: [TileCoordinateSpace.quantized(a + normal - along), TileCoordinateSpace.quantized(a - normal - along),
                       TileCoordinateSpace.quantized(b - normal + along), TileCoordinateSpace.quantized(b + normal + along)],
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
        let a = points[points.count - 2]
        let b = points[points.count - 1]
        let segment = simd_distance(a, b)
        guard segment > 1e-6 else { return nil }
        return (b, (b - a) / segment)
    }
}
