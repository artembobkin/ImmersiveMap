// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PreparedTileAvailabilityIndexTests: XCTestCase {
    func testFileNameParsing() {
        XCTAssertEqual(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "3_1_2.ptile"), Tile(x: 1, y: 2, z: 3))
        XCTAssertEqual(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "14_9905_5121.ptile"), Tile(x: 9905, y: 5121, z: 14))
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "3_1_2.ptgeo"), "the blob is not the entry")
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "3_1_2.ptile.tmp-ABCD"), "a staged file is not the entry")
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "3_1_2.ptgeo.tmp-ABCD"))
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "tile.ptile"))
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "3_1.ptile"))
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "a_b_c.ptile"))
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "3_1_2_4.ptile"))
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedTileFileName: "-3_1_2.ptile"))
        XCTAssertEqual(PreparedTileAvailabilityIndex.tile(forPreparedBlobFileName: "3_1_2.ptgeo"), Tile(x: 1, y: 2, z: 3))
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedBlobFileName: "3_1_2.ptile"))
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forPreparedBlobFileName: "3_1_2.ptgeo.tmp-ABCD"))
    }

    func testInsertRemoveAndReplace() {
        let index = PreparedTileAvailabilityIndex(timeToLive: 60)
        let a = Tile(x: 1, y: 2, z: 3)
        let b = Tile(x: 4, y: 5, z: 6)
        XCTAssertFalse(index.contains(a))
        index.insert(a, lastAccessDate: Date())
        XCTAssertTrue(index.contains(a))
        XCTAssertEqual(index.count, 1)
        index.remove(a)
        XCTAssertFalse(index.contains(a))
        index.replaceAll([a: Date(), b: Date()])
        XCTAssertTrue(index.contains(a))
        XCTAssertTrue(index.contains(b))
        index.removeAll()
        XCTAssertEqual(index.count, 0)
        XCTAssertFalse(index.contains(b))
    }

    func testAnExpiredEntryReadsAsAbsent() {
        let index = PreparedTileAvailabilityIndex(timeToLive: 100)
        let tile = Tile(x: 1, y: 2, z: 3)
        let now = Date()
        index.insert(tile, lastAccessDate: now.addingTimeInterval(-101))
        XCTAssertFalse(index.contains(tile, now: now))
        index.insert(tile, lastAccessDate: now.addingTimeInterval(-99))
        XCTAssertTrue(index.contains(tile, now: now))
        index.updateTimeToLive(50)
        XCTAssertFalse(index.contains(tile, now: now), "A shorter TTL expires it")
        index.updateTimeToLive(1000)
        XCTAssertTrue(index.contains(tile, now: now))
    }
}
