// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PMTiles
import PMTilesTestSupport
import XCTest

final class PMTilesDirectoryTests: XCTestCase {
    func testAWrittenDirectoryReadsBack() throws {
        let entries = [
            PMTilesEntry(tileID: 0, offset: 0, length: 10, runLength: 1),
            PMTilesEntry(tileID: 1, offset: 10, length: 20, runLength: 1),
            PMTilesEntry(tileID: 5, offset: 100, length: 5, runLength: 3),
            PMTilesEntry(tileID: 21, offset: 0, length: 10, runLength: 1),
        ]
        let decoded = try PMTilesDirectory(decoding: PMTilesArchiveWriter.encodeDirectory(entries))
        XCTAssertEqual(decoded.entries, entries)
    }

    func testAZeroOffsetChainsAfterThePreviousEntry() throws {
        // Hand-encoded: two entries, second offset written as 0.
        var data = Data()
        PMTilesArchiveWriter.appendVarint(&data, 2)
        PMTilesArchiveWriter.appendVarint(&data, 3)   // ids 3, then delta 4 = 7
        PMTilesArchiveWriter.appendVarint(&data, 4)
        PMTilesArchiveWriter.appendVarint(&data, 1)   // run lengths
        PMTilesArchiveWriter.appendVarint(&data, 1)
        PMTilesArchiveWriter.appendVarint(&data, 40)  // lengths
        PMTilesArchiveWriter.appendVarint(&data, 8)
        PMTilesArchiveWriter.appendVarint(&data, 101) // offset 100
        PMTilesArchiveWriter.appendVarint(&data, 0)   // follows: 140

        let decoded = try PMTilesDirectory(decoding: data)
        XCTAssertEqual(decoded.entries[0], PMTilesEntry(tileID: 3, offset: 100, length: 40, runLength: 1))
        XCTAssertEqual(decoded.entries[1], PMTilesEntry(tileID: 7, offset: 140, length: 8, runLength: 1))
    }

    func testARunCoversItsIDsAndNothingPastThem() {
        let directory = PMTilesDirectory(entries: [
            PMTilesEntry(tileID: 5, offset: 0, length: 9, runLength: 4),
        ])
        XCTAssertEqual(directory.lookup(tileID: 5), .tile(directory.entries[0]))
        XCTAssertEqual(directory.lookup(tileID: 8), .tile(directory.entries[0]))
        XCTAssertEqual(directory.lookup(tileID: 9), .missing)
        XCTAssertEqual(directory.lookup(tileID: 4), .missing)
    }

    func testALeafPointerAnswersEveryIDUpToTheNextEntry() {
        let leaf = PMTilesEntry(tileID: 21, offset: 0, length: 300, runLength: 0)
        let tile = PMTilesEntry(tileID: 85, offset: 0, length: 9, runLength: 1)
        let directory = PMTilesDirectory(entries: [leaf, tile])
        XCTAssertEqual(directory.lookup(tileID: 21), .leaf(leaf))
        XCTAssertEqual(directory.lookup(tileID: 60), .leaf(leaf))
        XCTAssertEqual(directory.lookup(tileID: 85), .tile(tile))
        XCTAssertEqual(directory.lookup(tileID: 86), .missing)
        XCTAssertEqual(directory.lookup(tileID: 3), .missing)
    }

    func testAnEmptyDirectoryAnswersMissing() throws {
        let decoded = try PMTilesDirectory(decoding: PMTilesArchiveWriter.encodeDirectory([]))
        XCTAssertEqual(decoded.lookup(tileID: 0), .missing)
    }

    func testATruncatedDirectoryThrows() {
        let full = PMTilesArchiveWriter.encodeDirectory([
            PMTilesEntry(tileID: 0, offset: 0, length: 10, runLength: 1),
            PMTilesEntry(tileID: 1, offset: 10, length: 20, runLength: 1),
        ])
        XCTAssertThrowsError(try PMTilesDirectory(decoding: full.prefix(full.count - 2))) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .truncated)
        }
    }

    func testAnAbsurdEntryCountIsMalformed() {
        var data = Data()
        PMTilesArchiveWriter.appendVarint(&data, UInt64.max)
        XCTAssertThrowsError(try PMTilesDirectory(decoding: data)) { error in
            guard case .malformedDirectory? = error as? PMTilesFormatError else {
                return XCTFail("expected malformedDirectory, got \(error)")
            }
        }
    }
}
