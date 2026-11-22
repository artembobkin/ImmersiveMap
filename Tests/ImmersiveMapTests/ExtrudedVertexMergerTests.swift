// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The merge of a building's vertices (`ExtrudedVertexMerger`): the same
/// triangles from fewer vertices, none of them twice within a building, and
/// no vertex shared by two buildings.
final class ExtrudedVertexMergerTests: XCTestCase {
    /// An L with a hole: convex corners, a concave one and an inner ring.
    private static let ell: [SIMD2<Float>] = [
        SIMD2(1000, 1000), SIMD2(1300, 1000), SIMD2(1300, 1100),
        SIMD2(1100, 1100), SIMD2(1100, 1300), SIMD2(1000, 1300)
    ]
    private static let hole: [SIMD2<Float>] = [
        SIMD2(1030, 1030), SIMD2(1070, 1030), SIMD2(1070, 1070), SIMD2(1030, 1070)
    ]

    private func mesh(radius: Float) throws -> ParsedExtrudedMesh {
        try XCTUnwrap(BuildingExtrusionMeshBuilder.build(clippedExterior: Self.ell,
                                                         clippedInteriors: [Self.hole],
                                                         roof: ParsedPolygon(vertices: Self.ell,
                                                                             indices: [0, 1, 2, 0, 2, 3, 0, 3, 5, 3, 4, 5]),
                                                         baseHeight: 0,
                                                         topHeight: 80,
                                                         edgeRadius: radius,
                                                         tileExtent: 4096))
    }

    private func bytes(_ vertex: ExtrudedVertexIn) -> [UInt8] {
        withUnsafeBytes(of: vertex) { Array($0) }
    }

    /// The corners of a mesh's triangles as the tile would hold them
    /// unmerged, in the order of its indices.
    private func corners(of mesh: ParsedExtrudedMesh, styleIndex: UInt8, ordinal: UInt16) -> [[UInt8]] {
        mesh.indices.map { index in
            let vertex = mesh.vertices[Int(index)]
            return bytes(ExtrudedVertexIn(position: vertex.position,
                                          normal: vertex.normal,
                                          styleIndex: styleIndex,
                                          buildingOrdinal: ordinal))
        }
    }

    func testARoundedBuildingKeepsItsTrianglesOnFewerVertices() throws {
        let rounded = try mesh(radius: 10)
        var merger = ExtrudedVertexMerger()
        var vertices: [ExtrudedVertexIn] = []
        var indices: [UInt32] = []
        merger.append(rounded, styleIndex: 2, buildingOrdinal: 7, vertices: &vertices, indices: &indices)

        XCTAssertEqual(indices.count, rounded.indices.count, "the building's run of the indices is as long as it was")
        XCTAssertEqual(indices.map { bytes(vertices[Int($0)]) },
                       corners(of: rounded, styleIndex: 2, ordinal: 7),
                       "every corner of every triangle has the position and the normal it had, in the same order")
        XCTAssertEqual(Set(vertices.map(bytes)).count, vertices.count, "no vertex is in the building twice")
        XCTAssertLessThan(vertices.count * 2, rounded.vertices.count,
                          "the faces of a rounded building share most of their corners")
    }

    func testASharpBoxLosesNoVertex() throws {
        let sharp = try mesh(radius: 0)
        var merger = ExtrudedVertexMerger()
        var vertices: [ExtrudedVertexIn] = []
        var indices: [UInt32] = []
        merger.append(sharp, styleIndex: 0, buildingOrdinal: 0, vertices: &vertices, indices: &indices)

        XCTAssertEqual(vertices.count, sharp.vertices.count, "every wall has its own normal")
        XCTAssertEqual(indices, sharp.indices)
    }

    /// Two volumes of the same bytes, as two buildings past the last
    /// ordinal can be, stay two.
    func testTwoBuildingsShareNoVertex() throws {
        let rounded = try mesh(radius: 10)
        var merger = ExtrudedVertexMerger()
        var vertices: [ExtrudedVertexIn] = []
        var indices: [UInt32] = []
        merger.append(rounded, styleIndex: 1, buildingOrdinal: .max, vertices: &vertices, indices: &indices)
        let firstVertexCount = vertices.count
        merger.append(rounded, styleIndex: 1, buildingOrdinal: .max, vertices: &vertices, indices: &indices)

        XCTAssertEqual(vertices.count, firstVertexCount * 2)
        let second = indices[rounded.indices.count...]
        XCTAssertTrue(second.allSatisfy { Int($0) >= firstVertexCount }, "the second building names its own vertices")
        XCTAssertEqual(second.map { bytes(vertices[Int($0)]) },
                       corners(of: rounded, styleIndex: 1, ordinal: .max))
    }
}
