// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PMTiles
import PMTilesTestSupport
import XCTest

final class PMTilesHeaderTests: XCTestCase {
    func testAWrittenHeaderReadsBack() throws {
        var writer = PMTilesArchiveWriter()
        writer.tiles = [.init(z: 0, x: 0, y: 0, data: Data([1, 2, 3]))]
        writer.minZoom = 0
        writer.maxZoom = 15
        let archive = writer.serializedData()

        let header = try PMTilesHeader(parsing: archive)
        XCTAssertEqual(header.rootDirectoryOffset, 127)
        XCTAssertEqual(header.internalCompression, .gzip)
        XCTAssertEqual(header.tileCompression, .gzip)
        XCTAssertEqual(header.tileType, .mvt)
        XCTAssertEqual(header.minZoom, 0)
        XCTAssertEqual(header.maxZoom, 15)
        XCTAssertTrue(header.isClustered)
        XCTAssertEqual(header.tileEntryCount, 1)
        XCTAssertEqual(header.minLongitude, -180, accuracy: 1e-6)
        XCTAssertEqual(header.maxLatitude, 85, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(header.rootDirectoryRange.upperBound, UInt64(PMTilesHeader.initialFetchByteCount))
        XCTAssertEqual(header.tileDataOffset + header.tileDataLength, UInt64(archive.count))
    }

    func testBadMagicIsRejected() {
        var bytes = Data(repeating: 0, count: 127)
        bytes.replaceSubrange(0..<7, with: Array("<!DOCTY".utf8))
        XCTAssertThrowsError(try PMTilesHeader(parsing: bytes)) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .badMagic)
        }
    }

    func testVersionTwoIsRejected() {
        var bytes = validHeaderBytes()
        bytes[7] = 2
        XCTAssertThrowsError(try PMTilesHeader(parsing: bytes)) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .unsupportedVersion(2))
        }
    }

    func testBrotliTilesAreRejected() {
        var bytes = validHeaderBytes()
        bytes[98] = PMTilesCompression.brotli.rawValue
        XCTAssertThrowsError(try PMTilesHeader(parsing: bytes)) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .unsupportedCompression(3))
        }
    }

    func testRasterTilesAreRejected() {
        var bytes = validHeaderBytes()
        bytes[99] = PMTilesTileType.png.rawValue
        XCTAssertThrowsError(try PMTilesHeader(parsing: bytes)) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .unsupportedTileType(2))
        }
    }

    func testAShortBufferIsTruncated() {
        XCTAssertThrowsError(try PMTilesHeader(parsing: validHeaderBytes().prefix(100))) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .truncated)
        }
    }

    private func validHeaderBytes() -> Data {
        var writer = PMTilesArchiveWriter()
        writer.tiles = [.init(z: 0, x: 0, y: 0, data: Data([1]))]
        return writer.serializedData()
    }
}
