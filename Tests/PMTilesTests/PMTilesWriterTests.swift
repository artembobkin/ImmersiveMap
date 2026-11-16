// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
@testable import PMTiles
import XCTest

/// The module's own writer, the one a baker writes an archive with: what it
/// writes, the module's reader reads back.
final class PMTilesWriterTests: XCTestCase {
    private func makeWriter() -> PMTilesWriter {
        var writer = PMTilesWriter()
        writer.tiles = [PMTilesWriter.Tile(zoom: 14, x: 9904, y: 5122, data: Data(repeating: 2, count: 3000)),
                        PMTilesWriter.Tile(zoom: 14, x: 9904, y: 5121, data: Data(repeating: 1, count: 2000))]
        writer.metadata = ["name": "models", "version": 6]
        return writer
    }

    func testAWrittenArchiveReadsBack() throws {
        let archive = try makeWriter().serialized()
        let header = try PMTilesHeader(parsing: archive, tileType: .unknown)

        XCTAssertTrue(header.isClustered)
        XCTAssertEqual(header.internalCompression, .gzip)
        XCTAssertEqual(header.tileCompression, .gzip)
        XCTAssertEqual([header.minZoom, header.maxZoom], [14, 14])
        XCTAssertEqual(header.tileEntryCount, 2)

        let rootBytes = archive.subdata(in: Int(header.rootDirectoryOffset)
                                        ..< Int(header.rootDirectoryOffset + header.rootDirectoryLength))
        let directory = try PMTilesDirectory(decoding: try PMTilesGzip.decompress(rootBytes, compression: .gzip))
        XCTAssertEqual(directory.entries.count, 2)
        XCTAssertEqual(directory.entries.map(\.tileID).sorted(), directory.entries.map(\.tileID),
                       "the entries are in the order of their ids")

        for (tile, fill) in [(PMTilesTileID.id(z: 14, x: 9904, y: 5121)!, UInt8(1)),
                             (PMTilesTileID.id(z: 14, x: 9904, y: 5122)!, UInt8(2))] {
            let entry = try XCTUnwrap(directory.entries.first { $0.tileID == tile })
            let range = header.tileDataRange(for: entry)
            let bytes = try PMTilesGzip.decompress(archive.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)),
                                                   compression: header.tileCompression)
            XCTAssertEqual(bytes, Data(repeating: fill, count: fill == 1 ? 2000 : 3000))
        }
    }

    func testTheMetadataIsWrittenAsJSON() throws {
        let archive = try makeWriter().serialized()
        let header = try PMTilesHeader(parsing: archive, tileType: .unknown)
        let bytes = archive.subdata(in: Int(header.metadataOffset)..<Int(header.metadataOffset + header.metadataLength))
        let object = try JSONSerialization.jsonObject(with: try PMTilesGzip.decompress(bytes, compression: .gzip))

        XCTAssertEqual((object as? [String: Any])?["name"] as? String, "models")
        XCTAssertEqual((object as? [String: Any])?["version"] as? Int, 6)
    }

    /// The header's bounds are the tiles' own edges.
    func testTheBoundsCoverTheTiles() throws {
        let header = try PMTilesHeader(parsing: try makeWriter().serialized(), tileType: .unknown)

        XCTAssertEqual(header.minLongitude, 37.6171875, accuracy: 1e-6)
        XCTAssertEqual(header.maxLongitude, 37.6391602, accuracy: 1e-6)
        XCTAssertLessThan(header.minLatitude, header.maxLatitude)
        XCTAssertEqual(header.maxLatitude, 55.7642132, accuracy: 1e-6)
    }

    func testAnArchiveOfNoTilesIsNotWritten() {
        XCTAssertThrowsError(try PMTilesWriter().serialized()) { error in
            XCTAssertEqual(error as? PMTilesWriterError, .noTiles)
        }
    }

    func testATileOutsideItsZoomIsTurnedAway() {
        var writer = PMTilesWriter()
        writer.tiles = [PMTilesWriter.Tile(zoom: 2, x: 4, y: 0, data: Data([1]))]
        XCTAssertThrowsError(try writer.serialized()) { error in
            XCTAssertEqual(error as? PMTilesWriterError, .tileOutsideItsZoom(zoom: 2, x: 4, y: 0))
        }
    }

    /// The reader holds a tile past its limit to be a corrupt length, so
    /// the writer does not write one.
    func testATileTheReaderWouldNotTakeIsTurnedAway() {
        var writer = PMTilesWriter()
        let byteCount = PMTilesWriter.maximumTileByteCount + 1
        writer.tiles = [PMTilesWriter.Tile(zoom: 14, x: 0, y: 0, data: Data(count: byteCount))]
        XCTAssertThrowsError(try writer.serialized()) { error in
            XCTAssertEqual(error as? PMTilesWriterError, .tileTooLarge(zoom: 14, x: 0, y: 0, byteCount: byteCount))
        }
    }

    func testAWrittenVarintReadsBack() throws {
        var data = Data()
        for value in [0, 1, 127, 128, 300, UInt64.max] {
            PMTilesVarint.append(value, to: &data)
        }
        var reader = PMTilesVarintReader(data)
        for value in [0, 1, 127, 128, 300, UInt64.max] {
            XCTAssertEqual(try reader.readUInt64(), value)
        }
        XCTAssertTrue(reader.isAtEnd)
    }
}
