// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The pieces the tiles cut a road into meet end to end at a node. Where
/// the stitcher leaves two pieces apart, each ends in a butt cut square to
/// its own last segment, and a bend between them opens a wedge of ground
/// on the outside of the turn. A connected end where the road goes on as
/// another piece of the SAME style is rounded off with a cap, which fills
/// the wedge at any angle and overlaps the next piece invisibly under the
/// road sheet. A junction with a road of another style keeps its square
/// ends, and so does a genuine free end.
final class RoadContinuationCapTests: XCTestCase {
    private let tile = Tile(x: 39615, y: 20486, z: 16)

    /// The node, off the tile centre and y-asymmetric (see TileCoordinateSpace).
    private let node: (Int32, Int32) = (1500, 900)

    private func parse(_ features: [VectorTileFixture.Feature]) throws -> ParsedTile {
        try TileMvtParser.forTests(settings: .default)
            .parse(tile: tile,
                   mvtData: VectorTileFixture.layerTile(layerName: "roads", features: features))
    }

    private func road(_ points: [(Int32, Int32)], id: UInt64, cls: String = "primary",
                      extra: [String: String] = [:]) -> VectorTileFixture.Feature {
        var properties = ProtomapsRoadSpelling.properties(forClass: cls)
        for (key, value) in extra { properties[key] = value }
        return .init(id: id, geometry: .line(points: points), properties: properties)
    }

    /// Two pieces of one road meeting at the node with a bend of about 20
    /// degrees, one arriving from the west, the other leaving north-east.
    private var westPiece: [(Int32, Int32)] { [(600, 900), node] }
    private var eastPiece: [(Int32, Int32)] { [node, (2400, 570)] }

    /// The cap fan triangles at the node in a road layer: a deferred ribbon
    /// carries its centreline in the positions, so every vertex of a cap
    /// sits on the node, and the rim vertices carry the extrusion
    /// direction. Only the cap's fan has a triangle whose three vertices
    /// all lie on the node.
    private func capTriangleCount(_ layer: DrawingGeometryLayer) -> Int {
        let vertices = layer.drawing.vertices
        let indices = layer.drawing.indices
        let expected = SIMD2<Int16>(Int16(node.0), Int16(Float(TileCoordinateSpace.tileExtentDouble) - Float(node.1)))
        var count = 0
        var index = 0
        while index + 2 < indices.count {
            let triangle = (0..<3).map { vertices[Int(indices[index + $0])] }
            if triangle.allSatisfy({ $0.position == expected })
                && triangle.contains(where: { $0.normal != .zero }) {
                count += 1
            }
            index += 3
        }
        return count
    }

    func testTwoPiecesOfOneStyleMeetingAtABendAreCappedAtTheNode() throws {
        // A service road ending at the node makes it a junction for the
        // stitcher, so the two primary pieces stay separate ribbons.
        let parsed = try parse([
            road(westPiece, id: 1),
            road(eastPiece, id: 2),
            road([node, (1500, 1800)], id: 3, cls: "service"),
        ])
        let fill = parsed.drawingRoadPhases.automobileGround.fill
        XCTAssertGreaterThanOrEqual(capTriangleCount(fill), 16,
                                    "Both connected ends of the primary get a round cap at the node")
    }

    func testPiecesWithoutAStreetIdentityAreCappedToo() throws {
        let parsed = try parse([
            road(westPiece, id: 1, cls: "service"),
            road(eastPiece, id: 2, cls: "service"),
        ])
        let fill = parsed.drawingRoadPhases.automobileGround.fill
        XCTAssertGreaterThanOrEqual(capTriangleCount(fill), 16,
                                    "Two service pieces the stitcher cannot join are capped at the node")
    }

    func testAJunctionOfTwoStylesKeepsSquareEnds() throws {
        let parsed = try parse([
            road(westPiece, id: 1, cls: "primary"),
            road(eastPiece, id: 2, cls: "secondary"),
        ])
        for layer in parsed.drawingRoadPhases.drawOrderBuckets.flatMap(\.drawOrderLayers) {
            XCTAssertEqual(capTriangleCount(layer), 0,
                           "A primary meeting a secondary is a junction, and neither end is rounded")
        }
    }

    func testAFreeEndIsNotCapped() throws {
        let parsed = try parse([road(westPiece, id: 1)])
        for layer in parsed.drawingRoadPhases.drawOrderBuckets.flatMap(\.drawOrderLayers) {
            XCTAssertEqual(capTriangleCount(layer), 0, "A road's free end stays a butt end")
        }
    }
}
