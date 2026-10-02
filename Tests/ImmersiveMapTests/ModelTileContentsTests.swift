// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The model tile's decoder: what a written tile reads back as, and what it
/// turns away. A tile comes from the network and from a disk cache, so its
/// bytes are untrusted, and a draw relies on every range the decoder passes.
final class ModelTileContentsTests: XCTestCase {
    func testAWrittenTileReadsBack() throws {
        var fixture = ModelTileFixture()
        fixture.layerCount = 2
        fixture.models = [
            ModelTileFixture.Model(id: "bolshoi", replaced: [(3, 3_334_755, 15)]),
            ModelTileFixture.Model(id: "okhotny-ryad",
                                   latitude: 55.7553,
                                   longitude: 37.6143,
                                   altitudeMeters: -6.5,
                                   cutsIntoGround: true,
                                   replaced: [(2, 31_560_418, 14), (3, 6_233_742, 15), (2, 228_130_090, 15), (1, 7, 15)],
                                   triangles: [[SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(0, 8, -2)],
                                               [SIMD3(1, 1, 1), SIMD3(5, 1, 1), SIMD3(1, 9, -1)]],
                                   layer: 1)
        ]
        let contents = try ModelTileContents(decoding: fixture.serialized())

        XCTAssertEqual(contents.tile, Tile(x: 9904, y: 5121, z: 14))
        XCTAssertEqual(contents.vertexCount, 9)
        XCTAssertEqual(contents.indexCount, 9)
        XCTAssertEqual(contents.mergedIndexCount, 3, "the model that cuts into the ground is drawn apart")
        XCTAssertEqual(contents.boundsMinimum, SIMD3(0, 0, -5))
        XCTAssertEqual(contents.boundsMaximum, SIMD3(10, 20, 1))
        XCTAssertEqual(contents.texture.layerCount, 2)
        XCTAssertEqual(contents.texture.blockEdge, 8)
        XCTAssertEqual(contents.texture.mipLevelCount, 5)
        XCTAssertEqual(contents.vertexRange.count, 9 * ModelTileContents.vertexStride)
        XCTAssertEqual(contents.textureRange.count, contents.texture.byteCount)

        XCTAssertEqual(contents.models.map(\.id), ["bolshoi", "okhotny-ryad"])
        let bolshoi = contents.models[0]
        XCTAssertEqual(bolshoi.replacedBuildings, [.init(element: .relation(3_334_755), mapTileZoom: 15)])
        XCTAssertFalse(bolshoi.cutsIntoGround)
        XCTAssertEqual(bolshoi.firstIndex, 0)
        XCTAssertEqual(bolshoi.indexCount, 3)
        XCTAssertEqual(bolshoi.boundsMinimum, SIMD3(0, 0, -5))
        XCTAssertEqual(bolshoi.boundsMaximum, SIMD3(10, 20, 0))

        let okhotny = contents.models[1]
        XCTAssertEqual(okhotny.replacedBuildings,
                       [.init(element: .way(31_560_418), mapTileZoom: 14),
                        .init(element: .relation(6_233_742), mapTileZoom: 15),
                        .init(element: .way(228_130_090), mapTileZoom: 15),
                        .init(element: .node(7), mapTileZoom: 15)],
                       "each feature with the zoom of the map tiles it is replaced in, in the tile's order")
        XCTAssertTrue(okhotny.cutsIntoGround)
        XCTAssertEqual(okhotny.firstIndex, 3)
        XCTAssertEqual(okhotny.indexCount, 6)
    }

    /// The bytes of a layer at each mip level, as the baker lays them out:
    /// whole blocks, one at the least.
    func testTheTextureLayoutCountsWholeBlocks() {
        let texture = ModelTileContents.Texture(width: 512, height: 512, mipLevelCount: 10, blockEdge: 8, layerCount: 3)

        XCTAssertEqual(texture.layerByteCount(level: 0), 64 * 64 * 16)
        XCTAssertEqual(texture.bytesPerRow(level: 0), 64 * 16)
        XCTAssertEqual(texture.layerByteCount(level: 6), 16, "an 8 pixel level is one block")
        XCTAssertEqual(texture.layerByteCount(level: 9), 16, "a 1 pixel level is one block still")
        XCTAssertEqual(texture.byteCount, 3 * 16 * (4096 + 1024 + 256 + 64 + 16 + 4 + 1 + 1 + 1 + 1))
    }

    func testAModelThatReplacesNothingListsNothing() throws {
        let contents = try ModelTileContents(decoding: ModelTileFixture().serialized())
        XCTAssertTrue(contents.models[0].replacedBuildings.isEmpty)
    }

    /// A tile of an earlier version of the format, which listed what a
    /// model replaces with no zoom, is not read: its archive is baked again.
    func testAnEarlierVersionIsTurnedAway() {
        var tile = ModelTileFixture().serialized()
        tile[4] = 3
        XCTAssertThrowsError(try ModelTileContents(decoding: tile)) { error in
            XCTAssertEqual(error as? ModelTileFormatError, .unsupportedVersion(3))
        }
    }

    /// The first bakes of this version wrote a zoom the models showed
    /// from, where the header now has a reserved field. There is no such
    /// rule, and an archive baked then reads as one baked now.
    func testTheReservedHeaderFieldIsIgnored() throws {
        let tile = ModelTileFixture().serialized()
        var earlier = tile
        earlier[108] = 15

        XCTAssertEqual(try ModelTileContents(decoding: earlier), try ModelTileContents(decoding: tile))
    }

    /// The one call draws the merged indices and nothing else: a count
    /// that reaches into a model drawn apart, or stops short of a merged
    /// one, is not a tile.
    func testAMergedIndexCountThatCutsThroughAModelIsTurnedAway() {
        var fixture = ModelTileFixture()
        fixture.models = [ModelTileFixture.Model(id: "plain"),
                          ModelTileFixture.Model(id: "sunk", cutsIntoGround: true)]
        var tile = fixture.serialized()
        XCTAssertEqual(try ModelTileContents(decoding: tile).mergedIndexCount, 3)

        tile[104] = 6
        XCTAssertThrowsError(try ModelTileContents(decoding: tile)) { error in
            guard case .malformed = error as? ModelTileFormatError else {
                return XCTFail("expected a malformed tile, got \(error)")
            }
        }
        tile[104] = 0
        XCTAssertThrowsError(try ModelTileContents(decoding: tile)) { error in
            guard case .malformed = error as? ModelTileFormatError else {
                return XCTFail("expected a malformed tile, got \(error)")
            }
        }
    }

    func testOtherBytesAreNotATile() {
        XCTAssertThrowsError(try ModelTileContents(decoding: Data(repeating: 0, count: 4096))) { error in
            XCTAssertEqual(error as? ModelTileFormatError, .badMagic)
        }
        XCTAssertThrowsError(try ModelTileContents(decoding: Data("IMMT".utf8))) { error in
            XCTAssertEqual(error as? ModelTileFormatError, .truncated)
        }
    }

    func testAnotherVersionIsTurnedAway() {
        var tile = ModelTileFixture().serialized()
        tile[4] = 5
        XCTAssertThrowsError(try ModelTileContents(decoding: tile)) { error in
            XCTAssertEqual(error as? ModelTileFormatError, .unsupportedVersion(5))
        }
    }

    /// A tile cut short by a failed download keeps its header, and the
    /// header then names blocks the bytes do not hold.
    func testATileCutShortIsTurnedAway() {
        let tile = ModelTileFixture().serialized()
        XCTAssertThrowsError(try ModelTileContents(decoding: tile.prefix(tile.count - 300))) { error in
            guard case .malformed = error as? ModelTileFormatError else {
                return XCTFail("expected a malformed tile, got \(error)")
            }
        }
    }

    /// The check of the vertex and index blocks, as the mesh runs it on the
    /// buffers the blocks were loaded into.
    private func checkGeometry(of tile: Data) throws {
        let contents = try ModelTileContents(decoding: tile)
        try tile.withUnsafeBytes { bytes in
            try contents.checkGeometry(vertices: UnsafeRawBufferPointer(rebasing: bytes[contents.vertexRange]),
                                       indices: UnsafeRawBufferPointer(rebasing: bytes[contents.indexRange]))
        }
    }

    func testAWrittenTilesGeometryPassesTheCheck() throws {
        XCTAssertNoThrow(try checkGeometry(of: ModelTileFixture().serialized()))
    }

    /// An index past the vertices would have the GPU read past the buffer.
    /// The tables say nothing of it: the check of the blocks does.
    func testAnIndexPastTheVerticesIsTurnedAway() throws {
        var tile = ModelTileFixture().serialized()
        let contents = try ModelTileContents(decoding: tile)
        tile[contents.indexRange.lowerBound] = 200
        XCTAssertNoThrow(try ModelTileContents(decoding: tile))
        XCTAssertThrowsError(try checkGeometry(of: tile)) { error in
            guard case .malformed = error as? ModelTileFormatError else {
                return XCTFail("expected a malformed tile, got \(error)")
            }
        }
    }

    func testALayerPastTheTextureArrayIsTurnedAway() throws {
        var fixture = ModelTileFixture()
        fixture.models[0].layer = 1
        XCTAssertThrowsError(try checkGeometry(of: fixture.serialized())) { error in
            guard case .malformed = error as? ModelTileFormatError else {
                return XCTFail("expected a malformed tile, got \(error)")
            }
        }
    }

    /// The blocks of another tile, shorter or longer, are not this tile's.
    func testBlocksOfAnotherSizeAreTurnedAway() throws {
        let tile = ModelTileFixture().serialized()
        let contents = try ModelTileContents(decoding: tile)
        try tile.withUnsafeBytes { bytes in
            let vertices = UnsafeRawBufferPointer(rebasing: bytes[contents.vertexRange])
            let indices = UnsafeRawBufferPointer(rebasing: bytes[contents.indexRange].dropLast(4))
            XCTAssertThrowsError(try contents.checkGeometry(vertices: vertices, indices: indices)) { error in
                XCTAssertEqual(error as? ModelTileFormatError, .truncated)
            }
        }
    }

    /// The decoder takes a slice of a larger buffer as it takes a whole
    /// one: the offsets in a tile count from the tile's own start.
    func testASliceOfALargerBufferDecodes() throws {
        let tile = ModelTileFixture().serialized()
        var buffer = Data(repeating: 0xAA, count: 100)
        buffer.append(tile)
        let slice = buffer.subdata(in: 100..<buffer.count)
        XCTAssertEqual(try ModelTileContents(decoding: buffer[100...]), try ModelTileContents(decoding: slice))
    }
}
