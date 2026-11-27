// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// From a pixel of the screen to the place on the map under it, the inverse
/// of the projection a frame drew with. Shared by every feature that tests
/// a tap against the ground (the layers of the app's data, the tile grid).
/// Pure: no Metal, no state, testable alone.
///
/// The world is the Web-Mercator one: x east and y south, 0 to 1 across the
/// world.
enum GeoScreenPlaceMath {
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

    /// The place under `pixel` (drawable pixels, origin bottom-left) by the
    /// projection of a frame, the search starting where the camera looks.
    static func place(under pixel: SIMD2<Double>,
                      constants: GeoScreenProjectionMath.FrameConstants) -> Place? {
        place(under: pixel, start: centre(of: constants), project: { project($0, constants) })
    }

    /// The world position the camera looks at, where the search for a
    /// tap's place starts.
    static func centre(of projection: GeoScreenProjectionMath.FrameConstants) -> SIMD2<Double> {
        switch projection.mode {
        case .flat:
            return ImmersiveMapProjection.centerWorldMercator(fromFlatPan: projection.flatPan)
        case .globe:
            return ImmersiveMapProjection.centerWorldMercator(fromGlobePan: SIMD2(Double(projection.globe.panX),
                                                                                  Double(projection.globe.panY)))
        }
    }

    /// The pixel a world position is drawn at, nil where the map does not
    /// show it.
    static func project(_ world: SIMD2<Double>,
                        _ projection: GeoScreenProjectionMath.FrameConstants) -> SIMD2<Double>? {
        let coordinate = coordinate(ofWorld: world)
        let output = GeoScreenProjectionMath.project(basis: GeoProjectionBasis(coordinate: coordinate),
                                                     constants: projection)
        guard output.visible != 0, output.visibilityAlpha > 0,
              output.position.x.isFinite, output.position.y.isFinite else {
            return nil
        }
        return SIMD2(Double(output.position.x), Double(output.position.y))
    }
}
