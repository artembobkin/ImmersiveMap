// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PMTiles
import PMTilesTestSupport
import XCTest

final class PMTilesGzipTests: XCTestCase {
    func testAGzipMemberInflates() throws {
        let original = Data((0..<10_000).map { UInt8($0 % 251) })
        let inflated = try PMTilesGzip.inflate(PMTilesArchiveWriter.gzip(original))
        XCTAssertEqual(inflated, original)
    }

    func testAMemberWithAFileNameInflates() throws {
        let original = Data("a tile with a name in its gzip header".utf8)
        let inflated = try PMTilesGzip.inflate(PMTilesArchiveWriter.gzip(original, fileName: "tile.mvt"))
        XCTAssertEqual(inflated, original)
    }

    func testDecompressPassesUncompressedDataThrough() throws {
        let original = Data([9, 8, 7])
        XCTAssertEqual(try PMTilesGzip.decompress(original, compression: .none), original)
        XCTAssertEqual(try PMTilesGzip.decompress(PMTilesArchiveWriter.gzip(original), compression: .gzip), original)
    }

    func testCorruptDataThrows() {
        var corrupt = PMTilesArchiveWriter.gzip(Data(repeating: 7, count: 500))
        corrupt[corrupt.count / 2] ^= 0xFF
        corrupt[corrupt.count / 2 + 1] ^= 0xFF
        XCTAssertThrowsError(try PMTilesGzip.inflate(corrupt)) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .corruptCompressedData)
        }
    }

    func testATruncatedMemberThrows() {
        let full = PMTilesArchiveWriter.gzip(Data(repeating: 7, count: 500))
        XCTAssertThrowsError(try PMTilesGzip.inflate(full.prefix(full.count - 10))) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .corruptCompressedData)
        }
    }

    func testNotGzipAtAllThrows() {
        XCTAssertThrowsError(try PMTilesGzip.inflate(Data("<html>".utf8))) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .corruptCompressedData)
        }
    }

    func testEmptyInputIsEmptyOutput() throws {
        XCTAssertEqual(try PMTilesGzip.inflate(Data()), Data())
    }
}
