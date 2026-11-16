// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import ModelTileFormat
import ModelTileFormatTestSupport
import simd
import XCTest

/// The model tile's writer, the one a baker makes a tile with: what it
/// writes is what the decoder reads, and a vertex lies in the bytes as the
/// format's reference says.
final class ModelTileWriterTests: XCTestCase {
    /// A tile of one triangle in a box from (10, 20, 0) to (110, 220, 50).
    private func makeTile() -> ModelTile {
        let minimum = SIMD3<Float>(10, 20, 0)
        let maximum = SIMD3<Float>(110, 220, 50)
        var vertices = Data()
        for position in [minimum, SIMD3<Float>(110, 20, 0), maximum] {
            var vertex = ModelTileVertex(normal: SIMD3(0, 0, 1), layer: 0, coordinate: SIMD2(0.5, 1))
            vertex.place(position, minimum: minimum, maximum: maximum)
            vertex.append(to: &vertices)
        }
        // A 16 pixel texture in 8x8 blocks: levels of 16, 8, 4, 2 and 1
        // pixels, four blocks and then one a level.
        let levels = [4, 1, 1, 1, 1].map { blocks in
            [Data((0..<blocks).flatMap { _ in ModelTileFixture.solidBlock })]
        }
        let model = ModelTile.Model(id: "bolshoi",
                                    latitude: 55.7602,
                                    longitude: 37.6186,
                                    altitudeMeters: 0,
                                    replacedBuildings: [.init(element: .relation(3_334_755), mapTileZoom: 15),
                                                        .init(element: .way(84_653_688), mapTileZoom: 14)],
                                    firstIndex: 0,
                                    indexCount: 3,
                                    firstVertex: 0,
                                    vertexCount: 3,
                                    boundsMinimum: minimum,
                                    boundsMaximum: maximum)
        return ModelTile(zoom: 14, x: 9904, y: 5121,
                         models: [model],
                         boundsMinimum: minimum,
                         boundsMaximum: maximum,
                         vertices: vertices,
                         indices: [0, 1, 2],
                         texture: ModelTile.Texture(width: 16, height: 16, blockEdge: 8, layerCount: 1, levels: levels))
    }

    func testAWrittenTileReadsBack() throws {
        let tile = makeTile()
        let bytes = tile.serialized()
        let contents = try ModelTileContents(decoding: bytes)

        XCTAssertEqual([contents.zoom, contents.x, contents.y], [14, 9904, 5121])
        XCTAssertEqual(contents.vertexCount, 3)
        XCTAssertEqual(contents.indexCount, 3)
        XCTAssertEqual(contents.boundsMinimum, tile.boundsMinimum)
        XCTAssertEqual(contents.boundsMaximum, tile.boundsMaximum)
        XCTAssertEqual(contents.texture, ModelTileContents.Texture(width: 16, height: 16, mipLevelCount: 5,
                                                                    blockEdge: 8, layerCount: 1))
        XCTAssertEqual(contents.models.map(\.id), ["bolshoi"])
        XCTAssertEqual(contents.models[0].replacedBuildings, tile.models[0].replacedBuildings)
        XCTAssertEqual(contents.models[0].firstIndex..<contents.models[0].indexCount, 0..<3)
        try bytes.withUnsafeBytes { raw in
            try contents.checkGeometry(vertices: UnsafeRawBufferPointer(rebasing: raw[contents.vertexRange]),
                                       indices: UnsafeRawBufferPointer(rebasing: raw[contents.indexRange]))
        }
    }

    /// The GPU's blocks start on the alignment the reference names, and the
    /// tile ends on it: a tile mapped from the disk hands them over whole.
    func testTheBlocksAreAligned() throws {
        let bytes = makeTile().serialized()
        let contents = try ModelTileContents(decoding: bytes)

        for offset in [contents.vertexRange.lowerBound, contents.indexRange.lowerBound,
                       contents.textureRange.lowerBound, bytes.count] {
            XCTAssertEqual(offset % ModelTileContents.blockAlignment, 0)
        }
    }

    /// A vertex is its sixteen bytes in the reference's order: the place in
    /// the tile's box, the texture coordinate, the normal, the layer and
    /// two reserved bytes.
    func testAVertexLiesAsTheReferenceSays() {
        var vertex = ModelTileVertex(normal: SIMD3(0, -1, 1), layer: 3, coordinate: SIMD2(0, 1))
        vertex.place(SIMD3(110, 120, 0), minimum: SIMD3(10, 20, 0), maximum: SIMD3(110, 220, 50))
        var block = Data()
        vertex.append(to: &block)

        XCTAssertEqual([UInt8](block), [0xFF, 0xFF, 0x00, 0x80, 0x00, 0x00,
                                        0x00, 0x00, 0xFF, 0xFF,
                                        0x00, 0x81, 0x7F, 0x03,
                                        0x00, 0x00])
        XCTAssertEqual(block.count, ModelTileContents.vertexStride)
    }

    /// The decoder's matrix takes a written place back to where it was, to
    /// within a step of the box.
    func testAPlacedPositionComesBackThroughTheTilesMatrix() throws {
        let tile = makeTile()
        let contents = try ModelTileContents(decoding: tile.serialized())
        var vertex = ModelTileVertex(normal: SIMD3(0, 0, 1), layer: 0, coordinate: SIMD2(0, 0))
        let position = SIMD3<Float>(47.3, 151.9, 12.4)
        vertex.place(position, minimum: tile.boundsMinimum, maximum: tile.boundsMaximum)

        let stored = SIMD3<Float>(Float(vertex.x), Float(vertex.y), Float(vertex.z)) / 65_535
        let back = contents.positionMatrix * SIMD4<Float>(stored, 1)
        let step = (tile.boundsMaximum - tile.boundsMinimum) / 65_535
        XCTAssertEqual(back.x, position.x, accuracy: step.x)
        XCTAssertEqual(back.y, position.y, accuracy: step.y)
        XCTAssertEqual(back.z, position.z, accuracy: step.z)
    }

    /// Two vertices of one surface at one place are one record, and a
    /// baker writes it once.
    func testVerticesOfOnePlaceAndSurfaceAreEqual() {
        let minimum = SIMD3<Float>(0, 0, 0)
        let maximum = SIMD3<Float>(100, 100, 100)
        var first = ModelTileVertex(normal: SIMD3(1, 0, 0), layer: 0, coordinate: SIMD2(0.25, 0.75))
        var second = first
        var other = ModelTileVertex(normal: SIMD3(0, 1, 0), layer: 0, coordinate: SIMD2(0.25, 0.75))
        first.place(SIMD3(5, 6, 7), minimum: minimum, maximum: maximum)
        second.place(SIMD3(5, 6, 7), minimum: minimum, maximum: maximum)
        other.place(SIMD3(5, 6, 7), minimum: minimum, maximum: maximum)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(Set([first, second, other]).count, 2)
    }
}
