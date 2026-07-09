// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class LRUMemoryCacheTests: XCTestCase {
    func testRetainsEntriesWhileTotalCostIsUnderLimit() {
        var cache = LRUMemoryCache<Int, String>(costLimit: 10)

        XCTAssertNil(cache.setValue("one", forKey: 1, cost: 2))
        XCTAssertNil(cache.setValue("two", forKey: 2, cost: 3))
        XCTAssertNil(cache.setValue("three", forKey: 3, cost: 4))

        XCTAssertEqual(cache.value(forKey: 1), "one")
        XCTAssertEqual(cache.value(forKey: 2), "two")
        XCTAssertEqual(cache.value(forKey: 3), "three")
        XCTAssertEqual(cache.totalCost, 9)
        XCTAssertEqual(cache.count, 3)
    }

    func testEvictsLeastRecentlyUsedEntriesWhenTotalCostExceedsLimit() {
        var cache = LRUMemoryCache<Int, String>(costLimit: 7)

        XCTAssertNil(cache.setValue("one", forKey: 1, cost: 3))
        XCTAssertNil(cache.setValue("two", forKey: 2, cost: 3))
        let evicted = cache.setValue("three", forKey: 3, cost: 3)

        XCTAssertEqual(evicted?.map(\.key), [1])
        XCTAssertNil(cache.value(forKey: 1))
        XCTAssertEqual(cache.value(forKey: 2), "two")
        XCTAssertEqual(cache.value(forKey: 3), "three")
        XCTAssertEqual(cache.totalCost, 6)
    }

    func testGetMarksEntryAsRecentlyUsed() {
        var cache = LRUMemoryCache<Int, String>(costLimit: 7)

        XCTAssertNil(cache.setValue("one", forKey: 1, cost: 3))
        XCTAssertNil(cache.setValue("two", forKey: 2, cost: 3))
        XCTAssertEqual(cache.value(forKey: 1), "one")
        let evicted = cache.setValue("three", forKey: 3, cost: 3)

        XCTAssertEqual(evicted?.map(\.key), [2])
        XCTAssertEqual(cache.value(forKey: 1), "one")
        XCTAssertNil(cache.value(forKey: 2))
        XCTAssertEqual(cache.value(forKey: 3), "three")
    }

    func testReplacingExistingEntryUpdatesCostAndRecency() {
        var cache = LRUMemoryCache<Int, String>(costLimit: 8)

        XCTAssertNil(cache.setValue("one", forKey: 1, cost: 3))
        XCTAssertNil(cache.setValue("two", forKey: 2, cost: 3))
        XCTAssertNil(cache.setValue("one updated", forKey: 1, cost: 4))
        let evicted = cache.setValue("three", forKey: 3, cost: 3)

        XCTAssertEqual(evicted?.map(\.key), [2])
        XCTAssertEqual(cache.value(forKey: 1), "one updated")
        XCTAssertNil(cache.value(forKey: 2))
        XCTAssertEqual(cache.value(forKey: 3), "three")
        XCTAssertEqual(cache.totalCost, 7)
    }

    func testOversizedEntryIsRetainedWhenItIsTheOnlyEntry() {
        var cache = LRUMemoryCache<Int, String>(costLimit: 5)

        XCTAssertNil(cache.setValue("large", forKey: 1, cost: 9))

        XCTAssertEqual(cache.value(forKey: 1), "large")
        XCTAssertEqual(cache.totalCost, 9)
        XCTAssertEqual(cache.count, 1)
    }

    func testRemoveAllReturnsSnapshotAndClearsCache() {
        var cache = LRUMemoryCache<Int, String>(costLimit: 10)
        _ = cache.setValue("one", forKey: 1, cost: 2)
        _ = cache.setValue("two", forKey: 2, cost: 3)

        let removed = cache.removeAll()

        XCTAssertEqual(removed.map(\.key), [1, 2])
        XCTAssertNil(cache.value(forKey: 1))
        XCTAssertNil(cache.value(forKey: 2))
        XCTAssertEqual(cache.totalCost, 0)
        XCTAssertEqual(cache.count, 0)
    }
}
