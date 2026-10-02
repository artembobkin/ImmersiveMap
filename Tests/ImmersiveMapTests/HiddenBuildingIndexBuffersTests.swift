// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// The working index buffer a tile's buildings draw from while models
/// stand in for some of them: a copy of the tile's indices without the
/// hidden buildings, drawn in one call, built when the hidden buildings
/// change and kept for the tile's life.
final class HiddenBuildingIndexBuffersTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        return device
    }

    /// A tile of three buildings, 3, 6 and 3 indices long, with ids 1, 2
    /// and 3. The indices count up from 0, behind `offset` bytes of other
    /// data, as a tile's index span sits inside its backing buffer.
    private func makeTile(device: MTLDevice, offset: Int = 8) throws -> MetalTile {
        let indices: [UInt16] = Array(0..<12)
        let buffer = try XCTUnwrap(device.makeBuffer(length: offset + indices.count * 2, options: .storageModeShared))
        indices.withUnsafeBytes { bytes in
            (buffer.contents() + offset).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        let extruded = TileBuffers.Extruded(vertices: nil,
                                            indices: TileBufferView(buffer: buffer, offset: offset, count: indices.count),
                                            styles: nil,
                                            indexType: .uint16,
                                            buildingRanges: [TileBuildingRange(featureID: 1, indexStart: 0, indexCount: 3),
                                                             TileBuildingRange(featureID: 2, indexStart: 3, indexCount: 6),
                                                             TileBuildingRange(featureID: 3, indexStart: 9, indexCount: 3)])
        return MetalTile(tile: Tile(x: 9904, y: 5121, z: 15),
                         tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers(extruded: extruded))
    }

    /// What the tile draws from with `ids` hidden in the map tiles of its
    /// zoom, as a frame asks: the hidden buildings first, then the tile.
    private func indices(_ buffers: HiddenBuildingIndexBuffers,
                         _ tile: MetalTile,
                         hiding ids: Set<UInt64>) -> HiddenBuildingIndexBuffers.Indices {
        buffers.update(ReplacedBuildings(byMapTileZoom: ids.isEmpty ? [:] : [15: ids]))
        return buffers.indices(of: tile)
    }

    private func contents(_ indices: HiddenBuildingIndexBuffers.Indices,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> (buffer: MTLBuffer, indices: [UInt16]) {
        guard case .working(let buffer, let indexCount) = indices else {
            XCTFail("expected a working buffer, got \(indices)", file: file, line: line)
            throw XCTSkip("no working buffer")
        }
        let pointer = buffer.contents().bindMemory(to: UInt16.self, capacity: indexCount)
        return (buffer, Array(UnsafeBufferPointer(start: pointer, count: indexCount)))
    }

    func testTheRunsAreCopiedOneAfterAnother() {
        let source: [UInt32] = Array(100..<112)
        var destination = [UInt32](repeating: 0, count: 6)
        source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                HiddenBuildingIndexBuffers.copy(runs: [0..<2, 5..<8, 11..<12],
                                                indexByteCount: 4,
                                                from: sourceBytes.baseAddress!,
                                                to: destinationBytes.baseAddress!)
            }
        }
        XCTAssertEqual(destination, [100, 101, 105, 106, 107, 111])
    }

    func testNothingHiddenDrawsTheTilesOwnBuffer() throws {
        let tile = try makeTile(device: makeDevice())
        let buffers = HiddenBuildingIndexBuffers()

        guard case .whole = indices(buffers, tile, hiding: []) else {
            return XCTFail("with nothing hidden the tile draws whole")
        }
        guard case .whole = indices(buffers, tile, hiding: [77]) else {
            return XCTFail("a building of another tile changes nothing here")
        }
    }

    /// The working buffer holds the tile's indices without the hidden
    /// building's, read from the tile's span inside its backing buffer.
    func testAHiddenBuildingIsLeftOutOfTheWorkingBuffer() throws {
        let tile = try makeTile(device: makeDevice())
        let buffers = HiddenBuildingIndexBuffers()

        XCTAssertEqual(try contents(indices(buffers, tile, hiding: [2])).indices, [0, 1, 2, 9, 10, 11])
        XCTAssertEqual(try contents(indices(buffers, tile, hiding: [1, 3])).indices, [3, 4, 5, 6, 7, 8])
    }

    func testATileWithEveryBuildingHiddenDrawsNothing() throws {
        let tile = try makeTile(device: makeDevice())
        guard case .none = indices(HiddenBuildingIndexBuffers(), tile, hiding: [1, 2, 3]) else {
            return XCTFail("every building is hidden")
        }
    }

    /// The buffer is built once and answers every frame after, in the world
    /// pass and in the shadow casters alike.
    func testTheWorkingBufferIsBuiltOnce() throws {
        let tile = try makeTile(device: makeDevice())
        let buffers = HiddenBuildingIndexBuffers()

        let first = try contents(indices(buffers, tile, hiding: [2])).buffer
        let second = try contents(indices(buffers, tile, hiding: [2])).buffer
        XCTAssertTrue(first === second)
    }

    /// The models gone (the camera has pulled back, or their tile was
    /// released), the tile draws its own buffer again, with every building.
    /// The working buffer waits, and the models' return costs nothing.
    func testTheWorkingBufferWaitsWhileNothingIsHidden() throws {
        let tile = try makeTile(device: makeDevice())
        let buffers = HiddenBuildingIndexBuffers()

        let first = try contents(indices(buffers, tile, hiding: [2])).buffer
        guard case .whole = indices(buffers, tile, hiding: []) else {
            return XCTFail("with nothing hidden the tile draws whole")
        }
        let afterReturn = try contents(indices(buffers, tile, hiding: [2])).buffer
        XCTAssertTrue(first === afterReturn)
    }

    /// Another tile of models loading changes the hidden set, and most map
    /// tiles hold none of its buildings: their working buffers stand.
    func testAChangeElsewhereKeepsTheWorkingBuffer() throws {
        let tile = try makeTile(device: makeDevice())
        let buffers = HiddenBuildingIndexBuffers()

        let first = try contents(indices(buffers, tile, hiding: [2])).buffer
        let afterChange = try contents(indices(buffers, tile, hiding: [2, 500, 600])).buffer
        XCTAssertTrue(first === afterChange)

        let rebuilt = try contents(indices(buffers, tile, hiding: [2, 3, 500]))
        XCTAssertFalse(rebuilt.buffer === first, "a change in this tile's buildings builds the buffer again")
        XCTAssertEqual(rebuilt.indices, [0, 1, 2])
    }

    /// An id is a building only within a zoom: the ids listed for the map
    /// tiles of zoom 14 are groups there, and take nothing out of a tile
    /// of zoom 15 that happens to carry the same id.
    func testATileTakesTheHiddenBuildingsOfItsOwnZoom() throws {
        let tile = try makeTile(device: makeDevice())
        let buffers = HiddenBuildingIndexBuffers()

        buffers.update(ReplacedBuildings(byMapTileZoom: [14: [2], 15: [77]]))
        guard case .whole = buffers.indices(of: tile) else {
            return XCTFail("a list for zoom 14 does not reach a tile of zoom 15")
        }
        buffers.update(ReplacedBuildings(byMapTileZoom: [14: [2], 15: [1]]))
        XCTAssertEqual(try contents(buffers.indices(of: tile)).indices, [3, 4, 5, 6, 7, 8, 9, 10, 11])
    }

    /// A landmark set through the settings names its buildings with no
    /// zoom: they are left out of every tile.
    func testBuildingsHiddenAtEveryZoomReachEveryTile() throws {
        let tile = try makeTile(device: makeDevice())
        let buffers = HiddenBuildingIndexBuffers()

        buffers.update(ReplacedBuildings(atEveryZoom: [3], byMapTileZoom: [15: [1]]))
        XCTAssertEqual(try contents(buffers.indices(of: tile)).indices, [3, 4, 5, 6, 7, 8])
    }

    /// A released tile's entry never answers for a later tile, even one
    /// that took its address: the entry is checked against the tile itself.
    func testEachTileHasItsOwnWorkingBuffer() throws {
        let device = try makeDevice()
        let buffers = HiddenBuildingIndexBuffers()
        let first = try makeTile(device: device)
        let second = try makeTile(device: device)

        let firstBuffer = try contents(indices(buffers, first, hiding: [2])).buffer
        let secondBuffer = try contents(indices(buffers, second, hiding: [2])).buffer
        XCTAssertFalse(firstBuffer === secondBuffer)
    }
}
