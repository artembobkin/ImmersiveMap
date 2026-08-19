// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Clips a road polyline against carriageway-surface polygons, keeping the
/// parts that lie outside them.
///
/// Where a junction area exists, the ribbon of the street it covers runs
/// inside it: the surface is that ground, so the ribbon draws only outside,
/// ending flush at the surface's edge. Each segment is cut at its exact
/// crossings of the polygon outlines and the pieces are classified by their
/// midpoint, so a segment that enters and leaves a surface contributes its two
/// outside ends and nothing in between.
enum RoadSurfaceClipper {
    static func clip(polyline: [SIMD2<Float>],
                     outside areas: [TileMvtParser.RoadSurfaceArea]) -> [[SIMD2<Float>]] {
        guard polyline.count >= 2, areas.isEmpty == false else { return [polyline] }

        var pieces: [[SIMD2<Float>]] = []
        var current: [SIMD2<Float>] = []

        func flush() {
            if current.count >= 2 { pieces.append(current) }
            current = []
        }

        for index in 0..<(polyline.count - 1) {
            let a = polyline[index]
            let b = polyline[index + 1]
            // Parameters along a->b where the segment crosses any area edge.
            var cuts: [Float] = [0, 1]
            for area in areas where segmentMayTouch(a, b, area) {
                let ring = area.exterior
                for k in 0..<ring.count {
                    let c = ring[k]
                    let d = ring[(k + 1) % ring.count]
                    if let t = intersectionParameter(a, b, c, d) {
                        cuts.append(t)
                    }
                }
            }
            cuts.sort()
            var previous: Float = 0
            for t in cuts.dropFirst() {
                guard t - previous > 1e-6 else { continue }
                let start = a + (b - a) * previous
                let end = a + (b - a) * t
                let midpoint = (start + end) * 0.5
                let covered = areas.contains { contains($0, midpoint) }
                if covered {
                    flush()
                } else {
                    if current.isEmpty { current.append(start) }
                    current.append(end)
                }
                previous = t
            }
        }
        flush()
        return pieces
    }

    private static func segmentMayTouch(_ a: SIMD2<Float>, _ b: SIMD2<Float>,
                                        _ area: TileMvtParser.RoadSurfaceArea) -> Bool {
        let lower = simd_min(a, b)
        let upper = simd_max(a, b)
        return lower.x <= area.bounds.max.x && upper.x >= area.bounds.min.x
            && lower.y <= area.bounds.max.y && upper.y >= area.bounds.min.y
    }

    /// Parameter along a->b of its crossing with segment c->d, or nil.
    private static func intersectionParameter(_ a: SIMD2<Float>, _ b: SIMD2<Float>,
                                              _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Float? {
        let r = b - a
        let s = d - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-9 else { return nil }
        let ac = c - a
        let t = (ac.x * s.y - ac.y * s.x) / denominator
        let u = (ac.x * r.y - ac.y * r.x) / denominator
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return t
    }

    private static func contains(_ area: TileMvtParser.RoadSurfaceArea, _ point: SIMD2<Float>) -> Bool {
        guard point.x >= area.bounds.min.x, point.x <= area.bounds.max.x,
              point.y >= area.bounds.min.y, point.y <= area.bounds.max.y else {
            return false
        }
        let ring = area.exterior
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let pi = ring[i]
            let pj = ring[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let x = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
