// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The math of a tap on the layers of the app's data. A tap is first turned
/// into the place on the map under it (`GeoScreenPlaceMath`), then tested
/// against the shapes there in the world's own space: a zone by whether it holds the place, a line
/// and a point by how far they are from it on screen. Pure: no Metal, no
/// state, testable alone.
///
/// The world is the Web-Mercator one of `LayerMeshBuilder`: x east and y
/// south, 0 to 1 across the world.
enum LayerPickMath {
    /// Whether a ring holds `point`, by the even-odd rule.
    static func ring(_ ring: [SIMD2<Double>], contains point: SIMD2<Double>) -> Bool {
        var inside = false
        var previous = ring.count - 1
        for index in ring.indices {
            let a = ring[index]
            let b = ring[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }

    /// How far the origin is from the segment `a`-`b`.
    static func distanceFromOrigin(toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return simd_length(a) }
        let t = min(max(-simd_dot(a, ab) / lengthSquared, 0), 1)
        return simd_length(a + ab * t)
    }

    /// Whether a box of degrees, widened by `margin`, holds `coordinate`,
    /// in whichever copy of the world its longitudes were written.
    static func box(of coordinates: [GeoCoordinate], holds coordinate: GeoCoordinate, margin: Double) -> Bool {
        guard var minimum = coordinates.first, var maximum = coordinates.first else { return false }
        for item in coordinates.dropFirst() {
            minimum.latitude = min(minimum.latitude, item.latitude)
            minimum.longitude = min(minimum.longitude, item.longitude)
            maximum.latitude = max(maximum.latitude, item.latitude)
            maximum.longitude = max(maximum.longitude, item.longitude)
        }
        guard coordinate.latitude >= minimum.latitude - margin, coordinate.latitude <= maximum.latitude + margin else {
            return false
        }
        // A shape across the 180th meridian written with a jump spans the
        // world in longitude: it is not ruled out here.
        if maximum.longitude - minimum.longitude > 180 { return true }
        return [-360.0, 0, 360].contains { turn in
            let longitude = coordinate.longitude + turn
            return longitude >= minimum.longitude - margin && longitude <= maximum.longitude + margin
        }
    }
}
