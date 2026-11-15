// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The math of a tap on the layers of the app's data. A tap is first turned
/// into the place on the map under it, then tested against the shapes there
/// in the world's own space: a zone by whether it holds the place, a line
/// and a point by how far they are from it on screen. Pure: no Metal, no
/// state, testable alone.
///
/// The world is the Web-Mercator one of `LayerMeshBuilder`: x east and y
/// south, 0 to 1 across the world.
enum LayerPickMath {
    /// A place on the map under a pixel, with how the screen moves round it.
    struct Place {
        let world: SIMD2<Double>
        /// Pixels per world unit at the place: a step in the world times
        /// this is the step on screen.
        let pixelsPerWorld: simd_double2x2

        /// How far `other` is from the place on screen, in pixels.
        func pixelOffset(to other: SIMD2<Double>) -> SIMD2<Double> {
            pixelsPerWorld * (other - world)
        }

        /// The most a step of `pixels` on screen can be in the world.
        func worldReach(ofPixels pixels: Double) -> Double {
            let inverse = pixelsPerWorld.inverse
            let norm = (simd_length_squared(inverse.columns.0) + simd_length_squared(inverse.columns.1)).squareRoot()
            return pixels * norm
        }
    }

    /// The place whose projection is `pixel`, found from `start` by
    /// Newton's method over `project`, which gives a world position's pixel
    /// and nil where the map does not show it (the far side of the globe,
    /// behind the camera). One method serves the globe, the flat map and
    /// the morph between them, since it asks only for the projection the
    /// frame drew with. Nil when the pixel is not on the map.
    static func place(under pixel: SIMD2<Double>,
                      start: SIMD2<Double>,
                      project: (SIMD2<Double>) -> SIMD2<Double>?) -> Place? {
        var world = start
        // The step the slope is measured over, kept near a few pixels.
        var step = 1e-3
        for _ in 0 ..< 32 {
            guard let here = project(world),
                  let east = project(world + SIMD2(step, 0)),
                  let south = project(world + SIMD2(0, step)) else {
                return nil
            }
            let jacobian = simd_double2x2(columns: ((east - here) / step, (south - here) / step))
            guard abs(jacobian.determinant) > .leastNonzeroMagnitude else { return nil }
            let residual = pixel - here
            let distance = simd_length(residual)
            if distance < 0.25 {
                return Place(world: world, pixelsPerWorld: jacobian)
            }
            let slope = max(simd_length(jacobian.columns.0), simd_length(jacobian.columns.1))
            step = min(max(4 / slope, 1e-13), 1e-3)

            // The whole step, or the largest part of it that comes nearer:
            // under a tilted camera a whole step can cross the horizon.
            let move = jacobian.inverse * residual
            var fraction = 1.0
            var moved = false
            for _ in 0 ..< 8 {
                var candidate = world + move * fraction
                candidate.y = min(max(candidate.y, 0), 1)
                if let there = project(candidate), simd_length(pixel - there) < distance {
                    world = candidate
                    moved = true
                    break
                }
                fraction /= 2
            }
            guard moved else { return nil }
        }
        return nil
    }

    static func coordinate(ofWorld world: SIMD2<Double>) -> GeoCoordinate {
        let x = world.x - world.x.rounded(.down)
        let latitude = atan(sinh(.pi * (1 - 2 * world.y))) * 180 / .pi
        return GeoCoordinate(latitude: latitude, longitude: x * 360 - 180)
    }

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
