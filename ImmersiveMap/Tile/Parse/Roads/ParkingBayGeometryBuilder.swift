// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Builds the parking-bay comb for a parking area polygon: the short white
/// stripes that divide a parking lot into bays.
///
/// OSM almost never maps individual `parking_space` polygons, so the comb is
/// synthesized from the polygon's own geometry, laid out the way real lots
/// are painted. The long axis of the polygon's minimum-area bounding
/// rectangle is the driving direction; bays run across it. A shallow strip
/// (one car deep) gets a single row of stripes across its whole depth; a
/// deeper lot alternates a bay row (~5 m) with a driving aisle (~6 m), which
/// is the layout the asphalt actually carries. A `parallel` orientation from
/// the tiles spreads the stripes to car-length spacing.
///
/// Input AND output are TILE space (y down): unlike its four sibling
/// decoration builders, this one never enters render space, because its
/// stripes are tessellated by `ParseLine.parse`, which owns its own entry
/// flip. A deliberate asymmetry; do not "unify" it with the flipping
/// builders, or the comb mirrors.
struct ParkingBayGeometryBuilder {
    /// A bay is ~2.6 m wide on the ground; parallel parking spaces are a car
    /// length apart instead.
    private static let bayStepMetres: Float = 2.6
    private static let parallelStepMetres: Float = 6.0
    /// One row of bays reaches ~5 m from the kerb; the aisle between two rows
    /// is ~6 m of bare asphalt.
    private static let rowDepthMetres: Float = 5.0
    private static let aisleDepthMetres: Float = 6.0
    /// Up to this depth the strip is one car deep and the stripes span it
    /// whole: a street-side band gets perpendicular bays edge to edge.
    private static let singleRowMaximumDepthMetres: Float = 8.0
    /// A row cut shorter than half a car by the polygon edge is dropped.
    private static let minimumRowDepthMetres: Float = 2.5
    /// A stripe piece shorter than this is a corner sliver, not a divider.
    static let minimumStripeMetres: Float = 1.8
    /// Runaway guard for degenerate giant polygons.
    private static let maximumStripes = 4000

    /// Ground metres one tile unit spans, from the Web Mercator scale at the
    /// tile's own latitude: the same fact the style derives its road widths
    /// from, restated here because the builder lays the comb out in metres.
    static func tileUnitsPerMetre(tile: Tile) -> Float {
        let tilesCount = Double(1 << tile.z)
        let normalizedY = (Double(tile.y) + 0.5) / tilesCount
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * normalizedY)))
        let metresPerTile = 40_075_016.686 * cos(latitude) / tilesCount
        return Float(4096.0 / metresPerTile)
    }

    /// The stripes for one exterior ring, as polylines of two points each,
    /// clipped to the ring. The ring arrives open (no closing duplicate) in
    /// tile space; interior rings are deliberately ignored, a hole in a
    /// parking lot is rare enough to accept a stripe across it.
    func buildStripes(exterior: [SIMD2<Float>],
                      unitsPerMetre: Float,
                      orientation: String?) -> [[SIMD2<Float>]] {
        guard exterior.count >= 3, unitsPerMetre > 0 else { return [] }

        // The minimum-area bounding rectangle, found the classic way: one of
        // its sides is collinear with a polygon edge, so trying every edge
        // direction is exhaustive.
        var best: (area: Float, axis: SIMD2<Float>, perp: SIMD2<Float>,
                   alongRange: ClosedRange<Float>, deepRange: ClosedRange<Float>)?
        for index in 0..<exterior.count {
            let a = exterior[index]
            let b = exterior[(index + 1) % exterior.count]
            let edge = b - a
            let length = simd_length(edge)
            guard length > 1e-3 else { continue }
            let u = edge / length
            let n = SIMD2<Float>(-u.y, u.x)
            var minU = Float.greatestFiniteMagnitude, maxU = -Float.greatestFiniteMagnitude
            var minN = Float.greatestFiniteMagnitude, maxN = -Float.greatestFiniteMagnitude
            for point in exterior {
                let du = simd_dot(point, u)
                let dn = simd_dot(point, n)
                minU = min(minU, du); maxU = max(maxU, du)
                minN = min(minN, dn); maxN = max(maxN, dn)
            }
            let area = (maxU - minU) * (maxN - minN)
            guard area > 0 else { continue }
            if best == nil || area < best!.area {
                if maxU - minU >= maxN - minN {
                    best = (area, u, n, minU...maxU, minN...maxN)
                } else {
                    best = (area, n, u, minN...maxN, minU...maxU)
                }
            }
        }
        guard let box = best else { return [] }

        // Rows across the depth: one for a shallow strip, alternating
        // bay row / aisle for a deep lot.
        let depthUnits = box.deepRange.upperBound - box.deepRange.lowerBound
        var rows: [(from: Float, to: Float)] = []
        if depthUnits <= Self.singleRowMaximumDepthMetres * unitsPerMetre {
            rows.append((box.deepRange.lowerBound, box.deepRange.upperBound))
        } else {
            let rowUnits = Self.rowDepthMetres * unitsPerMetre
            let aisleUnits = Self.aisleDepthMetres * unitsPerMetre
            var cursor = box.deepRange.lowerBound
            while cursor < box.deepRange.upperBound {
                let to = min(cursor + rowUnits, box.deepRange.upperBound)
                if to - cursor >= Self.minimumRowDepthMetres * unitsPerMetre {
                    rows.append((cursor, to))
                }
                cursor += rowUnits + aisleUnits
            }
        }

        let stepMetres = orientation == "parallel" ? Self.parallelStepMetres : Self.bayStepMetres
        let stepUnits = stepMetres * unitsPerMetre
        let minimumStripeUnits = Self.minimumStripeMetres * unitsPerMetre
        var stripes: [[SIMD2<Float>]] = []
        var along = box.alongRange.lowerBound + stepUnits * 0.5
        while along < box.alongRange.upperBound, stripes.count < Self.maximumStripes {
            for row in rows {
                let start = box.axis * along + box.perp * row.from
                let end = box.axis * along + box.perp * row.to
                for piece in Self.clipInside(ring: exterior, from: start, to: end)
                where simd_distance(piece.0, piece.1) >= minimumStripeUnits {
                    stripes.append([piece.0, piece.1])
                }
            }
            along += stepUnits
        }
        return stripes
    }

    /// The pieces of a segment that lie inside the ring: cut at every edge
    /// crossing, each piece classified by its midpoint with an even-odd ray,
    /// the same recipe `RoadSurfaceClipper` uses to keep the outside.
    private static func clipInside(ring: [SIMD2<Float>],
                                   from a: SIMD2<Float>,
                                   to b: SIMD2<Float>) -> [(SIMD2<Float>, SIMD2<Float>)] {
        var cuts: [Float] = [0, 1]
        let direction = b - a
        for index in 0..<ring.count {
            let c = ring[index]
            let d = ring[(index + 1) % ring.count]
            let edge = d - c
            let denominator = direction.x * edge.y - direction.y * edge.x
            guard abs(denominator) > 1e-9 else { continue }
            let delta = c - a
            let t = (delta.x * edge.y - delta.y * edge.x) / denominator
            let s = (delta.x * direction.y - delta.y * direction.x) / denominator
            if t > 0, t < 1, s >= 0, s <= 1 {
                cuts.append(t)
            }
        }
        cuts.sort()
        var pieces: [(SIMD2<Float>, SIMD2<Float>)] = []
        var previous: Float = 0
        for t in cuts.dropFirst() {
            guard t - previous > 1e-6 else { continue }
            let start = a + direction * previous
            let end = a + direction * t
            if contains(ring: ring, point: (start + end) * 0.5) {
                pieces.append((start, end))
            }
            previous = t
        }
        return pieces
    }

    private static func contains(ring: [SIMD2<Float>], point: SIMD2<Float>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let pi = ring[i]
            let pj = ring[j]
            if (pi.y > point.y) != (pj.y > point.y),
               point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
