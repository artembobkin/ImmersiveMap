// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Shared stroke geometry for the synthesized road-marking decorations.
///
/// The decoration builders used to emit one detached quad per segment with
/// butt caps, which is airtight only while every joint turns exactly ninety
/// degrees: anywhere else the caps left a notch on the outside of the corner
/// and stacked an overlap on the inside, and before the marking paint went
/// opaque every such overlap composited its alpha twice into a visibly
/// denser patch. A mitered band shares its joint vertices between the
/// neighbouring segment quads instead, so the stroke is seamless at any
/// angle, and because each shared vertex is quantized once, rounding to the
/// Int16 vertex grid cannot tear a joint open either.
enum RoadMarkingStrokeGeometry {
    /// The sharpest joint the miter follows before it is capped: below this
    /// cosine of the half-angle the miter point is clamped to about three
    /// half-strokes, so a hairpin in the input cannot fling a spike.
    private static let miterLimit: Float = 0.35

    /// One open polyline (already in render space, like everything the
    /// decoration builders emit) as one polygon: both offsets at half the
    /// stroke, interior joints mitered, ends cut with a perpendicular butt.
    static func miteredBand(points: [SIMD2<Float>],
                            stroke: Float) -> TileMvtParser.ParsedPolygon? {
        // Collapse degenerate steps first: a zero-length segment has no
        // direction to offset along.
        var path: [SIMD2<Float>] = []
        path.reserveCapacity(points.count)
        for point in points {
            if let last = path.last, simd_distance_squared(last, point) < 1e-6 {
                continue
            }
            path.append(point)
        }
        guard path.count >= 2, stroke > 0 else { return nil }

        let half = stroke * 0.5
        var vertices: [SIMD2<Int16>] = []
        vertices.reserveCapacity(path.count * 2)
        // The unrounded positions, for the winding decision below.
        var corners: [SIMD2<Float>] = []
        corners.reserveCapacity(path.count * 2)
        for index in 0..<path.count {
            let offset: SIMD2<Float>
            if index == 0 {
                offset = normal(path[0], path[1]) * half
            } else if index == path.count - 1 {
                offset = normal(path[index - 1], path[index]) * half
            } else {
                let before = normal(path[index - 1], path[index])
                let after = normal(path[index], path[index + 1])
                let sum = before + after
                let sumLength = simd_length(sum)
                if sumLength < 1e-4 {
                    // A full reversal: no miter exists, fall back to the
                    // incoming segment's butt.
                    offset = before * half
                } else {
                    let miter = sum / sumLength
                    offset = miter * (half / max(simd_dot(miter, before), miterLimit))
                }
            }
            corners.append(path[index] + offset)
            corners.append(path[index] - offset)
            vertices.append(TileCoordinateSpace.quantized(path[index] + offset))
            vertices.append(TileCoordinateSpace.quantized(path[index] - offset))
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((path.count - 1) * 6)
        for segment in 0..<(path.count - 1) {
            let left = UInt32(segment * 2)
            let right = left + 1
            let nextLeft = left + 2
            let nextRight = left + 3
            // Counter-clockwise in render space, like every tile triangle.
            // With `left` on the left of travel the quad runs that way by
            // itself; a full reversal of the path (the butt fallback above)
            // or a clamped miter can fold one quad over, so the order is
            // read off the quad's own area on the unrounded corners.
            let ring = [corners[Int(left)], corners[Int(right)], corners[Int(nextRight)], corners[Int(nextLeft)]]
            var doubledArea: Float = 0
            for corner in 0..<4 {
                let current = ring[corner]
                let next = ring[(corner + 1) % 4]
                doubledArea += current.x * next.y - next.x * current.y
            }
            if doubledArea < 0 {
                indices.append(contentsOf: [left, nextRight, right, left, nextLeft, nextRight])
            } else {
                indices.append(contentsOf: [left, right, nextRight, left, nextRight, nextLeft])
            }
        }
        return TileMvtParser.ParsedPolygon(vertices: vertices, indices: indices)
    }

    private static func normal(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
        let direction = simd_normalize(b - a)
        return SIMD2<Float>(-direction.y, direction.x)
    }
}
