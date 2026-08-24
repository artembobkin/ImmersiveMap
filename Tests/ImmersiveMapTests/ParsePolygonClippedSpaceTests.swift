// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The coordinate contract of `ParsePolygon`, stated directly instead of
/// through its consumers: `ParsedGeometry.clipped` stays in TILE space
/// (y down from the north edge, the Parse layer's working space), and the
/// tessellated `parsedPolygon` is RENDER space (y up), with the one flip
/// inside the tessellation, before the winding decisions.
final class ParsePolygonClippedSpaceTests: XCTestCase {
    /// A y-asymmetric quad poking past the NORTH edge (negative MVT y): the
    /// clip must cut it at y = 0 in tile space, never at the mirrored south
    /// edge, and the fixture cannot mirror onto itself.
    func testClippedRingsStayInTileSpaceAndVerticesFlipOnce() throws {
        let polygon = Polygon(exteriorRing: [Point(x: 600, y: -200),
                                             Point(x: 1400, y: -200),
                                             Point(x: 1400, y: 900),
                                             Point(x: 600, y: 900)],
                              interiorRings: [])
        let parsed = try XCTUnwrap(ParsePolygon().parseGeometry(polygon: polygon, tileExtent: 4096))

        let clippedYs = parsed.clipped.exterior.map(\.y)
        XCTAssertEqual(clippedYs.min() ?? -1, 0, accuracy: 0.001,
                       "The clip cuts at the tile's NORTH edge, y = 0 in tile space")
        XCTAssertEqual(clippedYs.max() ?? -1, 900, accuracy: 0.001,
                       "and the far side stays where the data put it: small y is north")

        // Every tessellated vertex is the same ring read through the one
        // flip: y_render = 4096 - y_tile.
        let renderYs = Set(parsed.parsedPolygon.vertices.map { Int($0.y) })
        XCTAssertEqual(renderYs, Set([4096, 4096 - 900]),
                       "The fill's vertices are the flipped ring, nothing else")
    }

    /// The flip precedes the winding decision: a convex ring tessellates
    /// with counter-clockwise triangles in render space regardless of which
    /// way the source ring winds in tile space.
    func testTriangleOrientationSurvivesTheFlip() throws {
        func orientation(ring: [Point]) throws -> Float {
            let parsed = try XCTUnwrap(ParsePolygon().parse(polygon: Polygon(exteriorRing: ring,
                                                                             interiorRings: []),
                                                            tileExtent: 4096))
            var doubled: Float = 0
            var index = 0
            while index + 2 < parsed.indices.count {
                let a = parsed.vertices[Int(parsed.indices[index])]
                let b = parsed.vertices[Int(parsed.indices[index + 1])]
                let c = parsed.vertices[Int(parsed.indices[index + 2])]
                doubled += Float(a.x) * Float(b.y - c.y)
                    + Float(b.x) * Float(c.y - a.y)
                    + Float(c.x) * Float(a.y - b.y)
                index += 3
            }
            return doubled
        }
        let ring = [Point(x: 600, y: 300), Point(x: 1400, y: 300),
                    Point(x: 1400, y: 900), Point(x: 600, y: 900)]
        let forward = try orientation(ring: ring)
        let reversed = try orientation(ring: ring.reversed())
        XCTAssertGreaterThan(forward, 0, "Triangles come out one way up in render space")
        XCTAssertGreaterThan(reversed, 0, "whichever way the source ring winds")

        // The concave (earcut) branch makes the same promise: a flip landing
        // after the winding decision there would slip past the convex fan.
        let concave = [Point(x: 600, y: 300), Point(x: 1400, y: 300),
                       Point(x: 1400, y: 900), Point(x: 1000, y: 500),
                       Point(x: 600, y: 900)]
        XCTAssertGreaterThan(try orientation(ring: concave), 0,
                             "Earcut triangles too")
        XCTAssertGreaterThan(try orientation(ring: concave.reversed()), 0,
                             "for both source windings")
    }
}
