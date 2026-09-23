// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import PMTiles
import XCTest

final class PMTilesDirectoryCacheTests: XCTestCase {
    private func directory(_ firstTileID: UInt64) -> PMTilesDirectory {
        PMTilesDirectory(entries: [PMTilesEntry(tileID: firstTileID, offset: 0, length: 1, runLength: 1)])
    }

    func testAStoredDirectoryIsReadBack() {
        var cache = PMTilesDirectoryCache(costLimit: 100)
        cache.insert(directory(7), atOffset: 42, cost: 10)
        XCTAssertEqual(cache.directory(atOffset: 42)?.entries.first?.tileID, 7)
        XCTAssertNil(cache.directory(atOffset: 43))
        XCTAssertEqual(cache.totalCost, 10)
    }

    func testTheLeastRecentlyUsedDirectoryGoesFirstWhenTheLimitIsExceeded() {
        var cache = PMTilesDirectoryCache(costLimit: 30)
        cache.insert(directory(1), atOffset: 1, cost: 10)
        cache.insert(directory(2), atOffset: 2, cost: 10)
        cache.insert(directory(3), atOffset: 3, cost: 10)
        cache.insert(directory(4), atOffset: 4, cost: 10)
        XCTAssertNil(cache.directory(atOffset: 1))
        XCTAssertNotNil(cache.directory(atOffset: 2))
        XCTAssertNotNil(cache.directory(atOffset: 4))
        XCTAssertEqual(cache.totalCost, 30)
    }

    func testAReadMakesADirectoryRecentAgain() {
        var cache = PMTilesDirectoryCache(costLimit: 30)
        cache.insert(directory(1), atOffset: 1, cost: 10)
        cache.insert(directory(2), atOffset: 2, cost: 10)
        cache.insert(directory(3), atOffset: 3, cost: 10)
        _ = cache.directory(atOffset: 1)
        cache.insert(directory(4), atOffset: 4, cost: 10)
        XCTAssertNotNil(cache.directory(atOffset: 1))
        XCTAssertNil(cache.directory(atOffset: 2))
    }

    func testOneCostlyDirectoryEvictsAsManyAsItNeeds() {
        var cache = PMTilesDirectoryCache(costLimit: 30)
        cache.insert(directory(1), atOffset: 1, cost: 10)
        cache.insert(directory(2), atOffset: 2, cost: 10)
        cache.insert(directory(3), atOffset: 3, cost: 25)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalCost, 25)
    }

    func testADirectoryCostlierThanTheLimitIsNotKept() {
        var cache = PMTilesDirectoryCache(costLimit: 30)
        cache.insert(directory(1), atOffset: 1, cost: 10)
        cache.insert(directory(2), atOffset: 2, cost: 31)
        XCTAssertNil(cache.directory(atOffset: 2))
        XCTAssertNotNil(cache.directory(atOffset: 1))
    }

    func testReplacingADirectoryCountsItsCostOnce() {
        var cache = PMTilesDirectoryCache(costLimit: 30)
        cache.insert(directory(1), atOffset: 1, cost: 10)
        cache.insert(directory(9), atOffset: 1, cost: 20)
        XCTAssertEqual(cache.totalCost, 20)
        XCTAssertEqual(cache.directory(atOffset: 1)?.entries.first?.tileID, 9)
    }

    func testRemoveAllEmptiesTheCache() {
        var cache = PMTilesDirectoryCache(costLimit: 30)
        cache.insert(directory(1), atOffset: 1, cost: 10)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }
}
