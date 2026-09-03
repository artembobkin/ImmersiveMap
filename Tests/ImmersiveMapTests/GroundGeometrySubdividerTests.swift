// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The grid split that lets coarse tile geometry follow the sphere: pieces
/// stay within one cell, area and attributes survive, and shared edges split
/// identically so no crack opens between neighbours.
final class GroundGeometrySubdividerTests: XCTestCase {
    func testStepFollowsTheTileZoom() {
        XCTAssertEqual(GroundGeometrySubdivider.step(forTileZoom: 0), 64)
        XCTAssertEqual(GroundGeometrySubdivider.step(forTileZoom: 1), 64)
        XCTAssertEqual(GroundGeometrySubdivider.step(forTileZoom: 2), 128)
        XCTAssertEqual(GroundGeometrySubdivider.step(forTileZoom: 3), 128)
        XCTAssertEqual(GroundGeometrySubdivider.step(forTileZoom: 4), 256)
        XCTAssertEqual(GroundGeometrySubdivider.step(forTileZoom: 6), 512)
        XCTAssertEqual(GroundGeometrySubdivider.step(forTileZoom: 9), 1024)
        XCTAssertNil(GroundGeometrySubdivider.step(forTileZoom: 10),
                     "From z10 the surface has unfurled: nothing is drawn on the sphere")
    }

    func testRibbonsSplitOnAQuadrupleStepGrid() {
        XCTAssertEqual(GroundGeometrySubdivider.ribbonStep(fillStep: 64), 256)
        XCTAssertEqual(GroundGeometrySubdivider.ribbonStep(fillStep: 1024), 4096)

        // One fill and one ribbon triangle of the same shape: after the
        // split the ribbon (line attributes present) must carry fewer
        // vertices than the fill, and both must respect their grid bound.
        let fill = TileMvtParser.ParsedPolygon(vertices: [SIMD2(0, 0), SIMD2(4096, 0), SIMD2(0, 4096)],
                                               indices: [0, 1, 2])
        var ribbon = fill
        ribbon.lineDistances = [127, 127, -127]
        ribbon.lineParameters = [0, Int16.max, Int16.max]
        var byStyle: [UInt8: [TileMvtParser.ParsedPolygon]] = [0: [fill], 1: [ribbon]]
        GroundGeometrySubdivider.subdivideIfNeeded(&byStyle, tileZoom: 0)

        let splitFill = byStyle[0]![0]
        let splitRibbon = byStyle[1]![0]
        XCTAssertLessThan(splitRibbon.vertices.count, splitFill.vertices.count,
                          "The ribbon grid is coarser, so it must produce fewer split vertices")
        let fillEdgeBound = Float(64) * Float(2).squareRoot() + 1
        let ribbonEdgeBound = Float(256) * Float(2).squareRoot() + 1
        assertEdges(of: splitFill, within: fillEdgeBound)
        assertEdges(of: splitRibbon, within: ribbonEdgeBound)
    }

    private func assertEdges(of polygon: TileMvtParser.ParsedPolygon, within bound: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        for triangle in stride(from: 0, to: polygon.indices.count, by: 3) {
            for edge in 0..<3 {
                let a = polygon.vertices[Int(polygon.indices[triangle + edge])]
                let b = polygon.vertices[Int(polygon.indices[triangle + (edge + 1) % 3])]
                let dx = Float(a.x) - Float(b.x)
                let dy = Float(a.y) - Float(b.y)
                XCTAssertLessThanOrEqual((dx * dx + dy * dy).squareRoot(), bound,
                                         "Every edge must fit inside one grid cell",
                                         file: file, line: line)
            }
        }
    }

    func testTileSpanningTriangleIsCutIntoCells() {
        let polygon = TileMvtParser.ParsedPolygon(vertices: [SIMD2(0, 0), SIMD2(4096, 0), SIMD2(0, 4096)],
                                                  indices: [0, 1, 2])
        let step = 1024
        let split = GroundGeometrySubdivider.subdivide(polygon, step: step)
        XCTAssertGreaterThan(split.indices.count, polygon.indices.count)
        XCTAssertEqual(split.indices.count % 3, 0)
        let maximumEdge = Float(step) * Float(2).squareRoot() + 1
        for triangle in stride(from: 0, to: split.indices.count, by: 3) {
            for edge in 0..<3 {
                let a = split.vertices[Int(split.indices[triangle + edge])]
                let b = split.vertices[Int(split.indices[triangle + (edge + 1) % 3])]
                let dx = Float(a.x) - Float(b.x)
                let dy = Float(a.y) - Float(b.y)
                XCTAssertLessThanOrEqual((dx * dx + dy * dy).squareRoot(), maximumEdge,
                                         "Every edge must fit inside one grid cell")
            }
        }
        XCTAssertEqual(signedArea(split), signedArea(polygon), accuracy: 1,
                       "The pieces cover exactly the input triangle")
    }

    /// The tile background is one quad; its diagonal runs corner to corner
    /// through every grid step that divides 4096, so the pieces are exactly
    /// the grid cells: two triangles per cell, one vertex per corner.
    func testTileQuadSubdividesIntoExactlyTheGridCells() {
        let quad = TileMvtParser.ParsedPolygon(vertices: [SIMD2(0, 0), SIMD2(4096, 0), SIMD2(4096, 4096), SIMD2(0, 4096)],
                                               indices: [0, 1, 2, 0, 2, 3])
        for step in [64, 128, 256, 512, 1024, 2048] {
            let cells = 4096 / step
            let split = GroundGeometrySubdivider.subdivide(quad, step: step)
            XCTAssertEqual(split.indices.count, cells * cells * 2 * 3, "step \(step): two triangles per cell")
            XCTAssertEqual(split.vertices.count, (cells + 1) * (cells + 1), "step \(step): one vertex per grid corner")
            XCTAssertEqual(signedArea(split), signedArea(quad), accuracy: 1, "step \(step): the pieces cover the quad")
            XCTAssertNil(TileMvtParser.ParsedPolygon.firstClockwiseTriangle(vertices: split.vertices, indices: split.indices),
                         "step \(step): every piece keeps the counter-clockwise winding")
        }
    }

    func testTriangleInsideOneCellPassesThroughUntouched() {
        let polygon = TileMvtParser.ParsedPolygon(vertices: [SIMD2(10, 10), SIMD2(60, 20), SIMD2(30, 50)],
                                                  indices: [0, 1, 2])
        let split = GroundGeometrySubdivider.subdivide(polygon, step: 64)
        XCTAssertEqual(split.vertices, polygon.vertices)
        XCTAssertEqual(split.indices, polygon.indices)
    }

    /// The fill outline rides through the split unsplit: its pairs are
    /// remapped to the deduplicated corner vertices and still name the
    /// same ring edges.
    func testFillOutlineIsRemappedToTheSplitVertices() {
        let quad = TileMvtParser.ParsedPolygon(vertices: [SIMD2(10, 10), SIMD2(200, 10), SIMD2(200, 150), SIMD2(10, 150)],
                                               indices: [0, 1, 2, 0, 2, 3],
                                               outlineIndices: [0, 1, 1, 2, 2, 3, 3, 0])
        let split = GroundGeometrySubdivider.subdivide(quad, step: 64)
        XCTAssertGreaterThan(split.vertices.count, quad.vertices.count, "The quad was split")
        XCTAssertEqual(split.outlineIndices.count, 8, "The outline keeps its four edges")
        let edges = stride(from: 0, to: 8, by: 2).map {
            (split.vertices[Int(split.outlineIndices[$0])], split.vertices[Int(split.outlineIndices[$0 + 1])])
        }
        XCTAssertEqual(edges.map { $0.0 }, quad.vertices)
        XCTAssertEqual(edges.map { $0.1 }, [quad.vertices[1], quad.vertices[2], quad.vertices[3], quad.vertices[0]])
    }

    func testAttributesInterpolateLinearlyAcrossASplit() {
        // A ribbon quad across one grid line at x = 64: the distance field
        // runs -127..127 across, the arc length 0..1000 along.
        let polygon = TileMvtParser.ParsedPolygon(vertices: [SIMD2(0, 0), SIMD2(128, 0), SIMD2(128, 10), SIMD2(0, 10)],
                                                  indices: [0, 1, 2, 0, 2, 3],
                                                  lineDistances: [-127, -127, 127, 127],
                                                  lineParameters: [0, 1000, 1000, 0])
        let split = GroundGeometrySubdivider.subdivide(polygon, step: 64)
        XCTAssertEqual(split.lineDistances.count, split.vertices.count)
        XCTAssertEqual(split.lineParameters.count, split.vertices.count)
        let onTheLine = split.vertices.indices.filter { split.vertices[$0].x == 64 }
        XCTAssertFalse(onTheLine.isEmpty)
        for index in onTheLine {
            XCTAssertEqual(split.lineParameters[index], 500, "Arc length halves at the middle of the quad")
            // The field is -127 on the bottom edge, 127 on the top edge, and
            // the diagonal's crossing sits halfway between them.
            switch split.vertices[index].y {
            case 0: XCTAssertEqual(split.lineDistances[index], -127)
            case 10: XCTAssertEqual(split.lineDistances[index], 127)
            case 5: XCTAssertEqual(split.lineDistances[index], 0)
            default: XCTFail("Unexpected crossing at y = \(split.vertices[index].y)")
            }
        }
    }

    func testSharedEdgesSplitIdentically() {
        // Two triangles sharing the diagonal (0,0)-(128,128), listed in
        // opposite directions: the crossing with x = 64 must be one vertex.
        let polygon = TileMvtParser.ParsedPolygon(vertices: [SIMD2(0, 0), SIMD2(128, 0), SIMD2(128, 128), SIMD2(0, 128)],
                                                  indices: [0, 1, 2, 2, 3, 0])
        let split = GroundGeometrySubdivider.subdivide(polygon, step: 64)
        let onDiagonal = split.vertices.filter { $0.x == 64 && $0.y == 64 }
        XCTAssertEqual(onDiagonal.count, 1, "The diagonal's crossing is shared, not duplicated")
        XCTAssertEqual(signedArea(split), signedArea(polygon), accuracy: 1)
    }

    func testWindingIsPreserved() {
        func crossings(_ split: TileMvtParser.ParsedPolygon) -> [Float] {
            stride(from: 0, to: split.indices.count, by: 3).map { triangle in
                let a = split.vertices[Int(split.indices[triangle])]
                let b = split.vertices[Int(split.indices[triangle + 1])]
                let c = split.vertices[Int(split.indices[triangle + 2])]
                return (Float(b.x) - Float(a.x)) * (Float(c.y) - Float(a.y))
                    - (Float(b.y) - Float(a.y)) * (Float(c.x) - Float(a.x))
            }
        }
        let counterClockwise = TileMvtParser.ParsedPolygon(vertices: [SIMD2(0, 0), SIMD2(200, 0), SIMD2(0, 200)],
                                                           indices: [0, 1, 2])
        for cross in crossings(GroundGeometrySubdivider.subdivide(counterClockwise, step: 64)) {
            XCTAssertGreaterThan(cross, 0, "Every piece keeps the input's counter-clockwise winding")
        }
        // A ribbon quad with attributes takes the fan and the split path alike.
        let ribbon = TileMvtParser.ParsedPolygon(vertices: [SIMD2(0, 0), SIMD2(128, 0), SIMD2(128, 10), SIMD2(0, 10)],
                                                 indices: [0, 1, 2, 0, 2, 3],
                                                 lineDistances: [-127, -127, 127, 127],
                                                 lineParameters: [0, 1000, 1000, 0])
        for cross in crossings(GroundGeometrySubdivider.subdivide(ribbon, step: 64)) {
            XCTAssertGreaterThan(cross, 0, "A split ribbon keeps its counter-clockwise winding")
        }
        // The subdivider is a pass-through, not the normalizer: a clockwise
        // input comes out clockwise in every piece. The emitters own the
        // winding contract (ParsedPolygon.firstClockwiseTriangle).
        let clockwise = TileMvtParser.ParsedPolygon(vertices: counterClockwise.vertices, indices: [0, 2, 1])
        let clockwisePieces = crossings(GroundGeometrySubdivider.subdivide(clockwise, step: 64))
        XCTAssertFalse(clockwisePieces.isEmpty)
        for cross in clockwisePieces {
            XCTAssertLessThan(cross, 0, "A clockwise input stays clockwise: the subdivider does not reorient")
        }
    }

    func testCoordinatesBeyondTheTileAreTolerated() {
        let polygon = TileMvtParser.ParsedPolygon(vertices: [SIMD2(-40, -40), SIMD2(4140, -40), SIMD2(-40, 4140)],
                                                  indices: [0, 1, 2])
        let split = GroundGeometrySubdivider.subdivide(polygon, step: 1024)
        XCTAssertEqual(signedArea(split), signedArea(polygon), accuracy: 1)
        XCTAssertTrue(split.vertices.contains { $0.x < 0 }, "The stitching margin survives")
    }

    private func signedArea(_ polygon: TileMvtParser.ParsedPolygon) -> Double {
        var area = 0.0
        for triangle in stride(from: 0, to: polygon.indices.count, by: 3) {
            let a = polygon.vertices[Int(polygon.indices[triangle])]
            let b = polygon.vertices[Int(polygon.indices[triangle + 1])]
            let c = polygon.vertices[Int(polygon.indices[triangle + 2])]
            area += (Double(b.x) - Double(a.x)) * (Double(c.y) - Double(a.y))
                - (Double(b.y) - Double(a.y)) * (Double(c.x) - Double(a.x))
        }
        return area / 2
    }
}
