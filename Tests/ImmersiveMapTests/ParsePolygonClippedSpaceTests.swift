// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest
import simd

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

    /// A fill as the hosted tiles produced it: a road surface a few units
    /// tall with holes for its crossings, rounded to the Int16 grid, which
    /// earcut handed back with one ear wound clockwise by more than the
    /// rounding tolerance (the debug funnel's assertion caught it at
    /// runtime). Settling the winding on the rounded vertices makes every
    /// triangle counter-clockwise without changing what they cover.
    func testWindingIsSettledOnTheRoundedVertices() {
        let points: [(Int16, Int16)] = [(2007, 71), (2020, 51), (2026, 48), (2033, 49), (2040, 54), (2080, 55), (2091, 62),
                                        (2091, 63), (2086, 62), (2080, 57), (2020, 57), (2010, 71), (2066, 60), (2067, 61),
                                        (2051, 50), (2051, 53), (2048, 51), (2048, 53), (2048, 54), (2039, 56), (2032, 51),
                                        (2024, 54), (2031, 52), (2031, 54), (2028, 50)]
        let indices: [UInt32] = [0, 1, 2, 2, 3, 4, 5, 6, 7, 7, 8, 9, 10, 11, 0, 5, 7, 9, 12, 5, 9, 12, 9, 13, 14, 12, 13,
                                 14, 13, 15, 4, 16, 17, 16, 14, 15, 16, 15, 17, 4, 17, 18, 4, 18, 19, 17, 15, 18, 4, 19, 20,
                                 2, 4, 20, 21, 22, 0, 0, 21, 2, 2, 20, 23, 10, 0, 2, 2, 23, 21, 21, 10, 2]
        var polygon = TileMvtParser.ParsedPolygon(vertices: points.map { SIMD2<Int16>($0.0, $0.1) }, indices: indices)
        XCTAssertEqual(TileMvtParser.ParsedPolygon.firstClockwiseTriangle(vertices: polygon.vertices, indices: polygon.indices), 19)

        polygon.windCounterClockwise()

        XCTAssertNil(TileMvtParser.ParsedPolygon.firstClockwiseTriangle(vertices: polygon.vertices, indices: polygon.indices))
        XCTAssertEqual(polygon.indices.count, indices.count)
        XCTAssertEqual(Set(polygon.indices), Set(indices), "the same vertices, only the order of a triangle's corners changes")
        for triangle in 0 ..< indices.count / 3 {
            let before = Set(indices[triangle * 3 ..< triangle * 3 + 3])
            let after = Set(polygon.indices[triangle * 3 ..< triangle * 3 + 3])
            XCTAssertEqual(before, after, "triangle \(triangle) keeps its corners")
        }
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

        // A ring with a hole goes through earcut's hole bridging, and a ring
        // poking past the north edge is clipped first: neither path may
        // leave a clockwise triangle behind, whichever way the source winds.
        func firstClockwise(exterior: [Point], interiors: [[Point]] = []) throws -> Int? {
            let parsed = try XCTUnwrap(ParsePolygon().parse(polygon: Polygon(exteriorRing: exterior,
                                                                             interiorRings: interiors),
                                                            tileExtent: 4096))
            return TileMvtParser.ParsedPolygon.firstClockwiseTriangle(vertices: parsed.vertices,
                                                                      indices: parsed.indices)
        }
        let hole = [Point(x: 900, y: 500), Point(x: 1100, y: 500),
                    Point(x: 1100, y: 700), Point(x: 900, y: 700)]
        XCTAssertNil(try firstClockwise(exterior: ring, interiors: [hole]), "A ring with a hole")
        XCTAssertNil(try firstClockwise(exterior: ring.reversed(), interiors: [hole.reversed()]),
                     "for both source windings")
        let pastTheNorthEdge = [Point(x: 600, y: -200), Point(x: 1400, y: -200), Point(x: 1400, y: 900),
                                Point(x: 1000, y: 500), Point(x: 600, y: 900)]
        XCTAssertNil(try firstClockwise(exterior: pastTheNorthEdge), "A clipped concave ring")
        XCTAssertNil(try firstClockwise(exterior: pastTheNorthEdge.reversed()), "for both source windings")
    }
}
