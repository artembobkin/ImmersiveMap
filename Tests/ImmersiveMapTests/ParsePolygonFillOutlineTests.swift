// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest
import simd

/// The fill outline a tessellated polygon carries for its edge
/// antialiasing: a line list of its ring edges over the fill's own vertex
/// order, with the edges lying on the tile boundary left out.
final class ParsePolygonFillOutlineTests: XCTestCase {
    private func parsed(_ polygon: Mvt.Polygon) throws -> TileMvtParser.ParsedPolygon {
        try XCTUnwrap(ParsePolygon().parse(polygon: polygon, tileExtent: 4096))
    }

    private func outlineEdges(_ polygon: TileMvtParser.ParsedPolygon) -> [(SIMD2<Int16>, SIMD2<Int16>)] {
        stride(from: 0, to: polygon.outlineIndices.count, by: 2).map { start in
            (polygon.vertices[Int(polygon.outlineIndices[start])],
             polygon.vertices[Int(polygon.outlineIndices[start + 1])])
        }
    }

    /// A square well inside the tile: four edges, each pair naming two
    /// consecutive ring vertices, every vertex of the fill used.
    func testInteriorSquareOutlinesEveryEdge() throws {
        let square = Polygon(exteriorRing: [Point(x: 1000, y: 1000), Point(x: 2000, y: 1000),
                                            Point(x: 2000, y: 2000), Point(x: 1000, y: 2000)],
                             interiorRings: [])
        let polygon = try parsed(square)
        XCTAssertEqual(polygon.outlineIndices.count, 8, "Four edges, two indices each")
        for edge in outlineEdges(polygon) {
            let delta = SIMD2<Int>(Int(edge.1.x) - Int(edge.0.x), Int(edge.1.y) - Int(edge.0.y))
            XCTAssertEqual(abs(delta.x) + abs(delta.y), 1000, "Each outline edge is one side of the square")
        }
        XCTAssertEqual(Set(polygon.outlineIndices), Set(0..<UInt32(polygon.vertices.count)),
                       "The outline indexes exactly the fill's vertices")
    }

    /// A polygon clipped by the tile: the clip edge along the tile boundary
    /// is not a feature edge and gets no outline; the three real sides do.
    func testEdgesOnTheTileBoundaryGetNoOutline() throws {
        let overhanging = Polygon(exteriorRing: [Point(x: 1000, y: -500), Point(x: 2000, y: -500),
                                                 Point(x: 2000, y: 1000), Point(x: 1000, y: 1000)],
                                  interiorRings: [])
        let polygon = try parsed(overhanging)
        let edges = outlineEdges(polygon)
        XCTAssertEqual(edges.count, 3, "The clipped north side is the tile boundary, not an edge")
        for edge in edges {
            // Render space puts the north boundary at y = 4096.
            XCTAssertFalse(edge.0.y == 4096 && edge.1.y == 4096,
                           "No outline may lie along the tile boundary")
        }
    }

    /// A polygon with a hole goes through earcut, which keeps the exterior
    /// and the hole in ring order: both rings are outlined.
    func testHoleRingsAreOutlinedToo() throws {
        let ring = Polygon(exteriorRing: [Point(x: 500, y: 500), Point(x: 3500, y: 500),
                                          Point(x: 3500, y: 3500), Point(x: 500, y: 3500)],
                           interiorRings: [[Point(x: 1500, y: 1500), Point(x: 1500, y: 2500),
                                            Point(x: 2500, y: 2500), Point(x: 2500, y: 1500)]])
        let polygon = try parsed(ring)
        XCTAssertEqual(polygon.vertices.count, 8)
        XCTAssertEqual(polygon.outlineIndices.count, 16, "Four outer edges and four hole edges")
        let holeEdges = outlineEdges(polygon).filter { edge in
            (1500...2500).contains(Int(edge.0.x)) && (1500...2500).contains(Int(edge.1.x))
        }
        XCTAssertEqual(holeEdges.count, 4)
    }

    /// The tile-boundary decision reads the ring as tessellated: a ring
    /// entirely on one boundary line has no edges left at all.
    func testOutlineHelperSkipsEveryBoundaryEdge() {
        let onTheWestEdge: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 100), SIMD2(0, 200)]
        XCTAssertEqual(ParsePolygon.outlineIndices(rings: [onTheWestEdge], tileExtent: 4096), [])
        let acrossTheTile: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4096, 0), SIMD2(4096, 4096)]
        XCTAssertEqual(ParsePolygon.outlineIndices(rings: [acrossTheTile], tileExtent: 4096), [2, 0],
                       "Only the diagonal, which touches both boundaries without lying on one, remains")
    }
}
