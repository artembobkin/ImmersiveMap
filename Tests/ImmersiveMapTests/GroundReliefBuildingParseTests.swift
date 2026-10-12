// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The buildings on a relief: every extruded vertex carries its volume's
/// ordinal in the tile, and the tile lists each volume's anchor, the centre
/// of its footprint's bounds, so the relief lifts a building whole, by the
/// terrain under its anchor, and it stands level on a slope.
final class GroundReliefBuildingParseTests: XCTestCase {
    private static let tile = Tile(x: 9651, y: 12319, z: 15)

    func testEveryVolumeHasAnOrdinalAndAnAnchorAtItsFootprintsCentre() throws {
        // Two square buildings, tile space (y down): the first at
        // 512...1024 in x and 1024...1536 in y, the second lower right.
        let data = VectorTileFixture.layerTile(layerName: "buildings", features: [
            .building(id: 1, ring: [(512, 1024), (1024, 1024), (1024, 1536), (512, 1536)], height: "30"),
            .building(id: 2, ring: [(2048, 2560), (3072, 2560), (3072, 3584), (2048, 3584)], height: "12")
        ])
        let parsed = try TileMvtParser.forTests(settings: .default).parse(tile: Self.tile, mvtData: data)
        let extruded = parsed.drawingExtruded
        XCTAssertEqual(extruded.buildingAnchors.count, 2)
        // Render space is y up: the anchors' y is the extent less the tile y.
        let extent = TileCoordinateSpace.tileExtent
        let anchors = Set(extruded.buildingAnchors.map { SIMD2<Int>(Int($0.x.rounded()), Int($0.y.rounded())) })
        XCTAssertEqual(anchors, [SIMD2<Int>(768, Int(extent) - 1280), SIMD2<Int>(2560, Int(extent) - 3072)])
        let ordinals = Set(extruded.vertices.map(\.buildingOrdinal))
        XCTAssertEqual(ordinals, [0, 1], "Every vertex names one of the two volumes")
        // The ordinal names the volume the vertex belongs to: its position
        // lies within that anchor's footprint.
        for vertex in extruded.vertices {
            let anchor = extruded.buildingAnchors[Int(vertex.buildingOrdinal)]
            let position = SIMD2<Float>(Float(vertex.positionX), Float(vertex.positionY)) / ExtrudedVertexIn.positionScale
            XCTAssertLessThanOrEqual(abs(position.x - anchor.x), 520, "x of a vertex of volume \(vertex.buildingOrdinal)")
            XCTAssertLessThanOrEqual(abs(position.y - anchor.y), 520, "y of a vertex of volume \(vertex.buildingOrdinal)")
        }
    }

    func testTheVertexKeepsItsTwelveBytes() {
        XCTAssertEqual(MemoryLayout<ExtrudedVertexIn>.stride, 12)
        let vertex = ExtrudedVertexIn(position: SIMD3<Float>(1, 2, 3), normal: SIMD3<Float>(0, 0, 1), styleIndex: 4, buildingOrdinal: 513)
        XCTAssertEqual(vertex.buildingOrdinal, 513)
        XCTAssertEqual(vertex.styleIndex, 4)
    }
}
