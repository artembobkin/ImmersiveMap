// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

/// The working-set contract: residency is the demanded set, the pinned
/// world cover, and the retention of the last `retentionLimit` tiles the
/// demand stopped naming, oldest out first.
final class TileWorkingSetStoreTests: XCTestCase {
    /// Releases `count` fresh tiles through the demand so the retention
    /// fills past whatever it held.
    private func fillRetention(_ store: TileWorkingSetStore, count: Int = TileWorkingSetStore.retentionLimit) throws {
        for index in 0 ..< count {
            let tile = Tile(x: 1000 + index, y: 1000, z: 12)
            store.insert(try makeMetalTile(tile), forKey: tile)
            store.updateDemandedTiles([tile])
        }
        store.updateDemandedTiles([] as [Tile])
    }

    func testDemandedTileStaysResidentAcrossDemandUpdates() throws {
        let store = makeStore()
        let tile = Tile(x: 5, y: 6, z: 10)
        store.insert(try makeMetalTile(tile), forKey: tile)

        store.updateDemandedTiles([tile])
        store.updateDemandedTiles([tile])

        XCTAssertNotNil(store.tile(forKey: tile))
    }

    func testTileLeavingTheDemandedSetIsRetainedUntilTheRetentionFills() throws {
        let store = makeStore()
        let staying = Tile(x: 1, y: 0, z: 10)
        let leaving = Tile(x: 2, y: 0, z: 10)
        store.insert(try makeMetalTile(staying), forKey: staying)
        store.insert(try makeMetalTile(leaving), forKey: leaving)

        store.updateDemandedTiles([staying])

        XCTAssertNotNil(store.tile(forKey: staying))
        XCTAssertNotNil(store.tile(forKey: leaving), "A tile that just left the demand is retained")
        XCTAssertEqual(store.retainedTiles, [leaving])

        try fillRetention(store)
        XCTAssertNil(store.tile(forKey: leaving), "The oldest retained tile goes once the retention is full")
        XCTAssertEqual(store.retainedTiles.count, TileWorkingSetStore.retentionLimit)
    }

    func testARetainedTileDemandedAgainLeavesTheRetention() throws {
        let store = makeStore()
        let tile = Tile(x: 2, y: 0, z: 10)
        store.insert(try makeMetalTile(tile), forKey: tile)
        store.updateDemandedTiles([] as [Tile])
        XCTAssertEqual(store.retainedTiles, [tile])

        store.updateDemandedTiles([tile])
        XCTAssertTrue(store.retainedTiles.isEmpty, "Demanded again, the tile is active, not retained")
        XCTAssertNotNil(store.tile(forKey: tile))

        // Filling the retention no longer touches it.
        for index in 0 ..< TileWorkingSetStore.retentionLimit + 2 {
            let other = Tile(x: 1000 + index, y: 1000, z: 12)
            store.insert(try makeMetalTile(other), forKey: other)
            store.updateDemandedTiles([tile, other])
        }
        store.updateDemandedTiles([tile])
        XCTAssertNotNil(store.tile(forKey: tile))
    }

    func testInsertOutsideDemandIsRetained() throws {
        // Offscreen harnesses parse tiles before any frame has demanded them;
        // the store must hold such a tile until demand actually speaks, and
        // then in the retention.
        let store = makeStore()
        let tile = Tile(x: 3, y: 3, z: 12)

        store.insert(try makeMetalTile(tile), forKey: tile)
        XCTAssertNotNil(store.tile(forKey: tile))

        store.updateDemandedTiles([] as [Tile])
        XCTAssertNotNil(store.tile(forKey: tile))
        XCTAssertEqual(store.retainedTiles, [tile])
    }

    /// More tiles leave in one frame than the retention holds (a level
    /// change): the ones that were nearest the camera, first in the demand
    /// order, are the ones kept.
    func testSameFrameLeaversKeepTheNearestOnes() throws {
        let store = makeStore()
        var ordered: [Tile] = []
        for index in 0 ..< TileWorkingSetStore.retentionLimit + 5 {
            // Reverse x so the z/x/y order would keep the wrong end.
            let tile = Tile(x: 500 - index, y: 7, z: 12)
            ordered.append(tile)
            store.insert(try makeMetalTile(tile), forKey: tile)
        }
        store.updateDemandedTiles(ordered)
        store.updateDemandedTiles([] as [Tile])

        let kept = Set(store.retainedTiles)
        XCTAssertEqual(kept, Set(ordered.prefix(TileWorkingSetStore.retentionLimit)),
                       "The retention keeps the tiles that stood first in the demand")
        XCTAssertEqual(store.retainedTiles.first, ordered[TileWorkingSetStore.retentionLimit - 1],
                       "and the farthest of them is the next to go")
    }

    func testATileThatLeavesAgainGoesToTheBackOfTheQueue() throws {
        let store = makeStore(retentionLimit: 2)
        let first = Tile(x: 1, y: 0, z: 10)
        let second = Tile(x: 2, y: 0, z: 10)
        store.insert(try makeMetalTile(first), forKey: first)
        store.insert(try makeMetalTile(second), forKey: second)
        store.updateDemandedTiles([first, second])
        store.updateDemandedTiles([second])
        store.updateDemandedTiles([] as [Tile])
        XCTAssertEqual(store.retainedTiles, [first, second])

        store.updateDemandedTiles([first])
        store.updateDemandedTiles([] as [Tile])
        XCTAssertEqual(store.retainedTiles, [second, first], "re-demanded and released again, first is now the newest")
    }

    func testInsertingARetainedTileKeepsOneRetentionEntry() throws {
        let store = makeStore()
        let tile = Tile(x: 2, y: 0, z: 10)
        store.insert(try makeMetalTile(tile), forKey: tile)
        store.updateDemandedTiles([] as [Tile])
        store.insert(try makeMetalTile(tile), forKey: tile)
        store.updateDemandedTiles([] as [Tile])
        XCTAssertEqual(store.retainedTiles, [tile])
        XCTAssertEqual(store.residentTileCount, 1)
    }

    func testResidentTilesListsTheRetentionToo() throws {
        let store = makeStore()
        let active = Tile(x: 1, y: 0, z: 10)
        let retained = Tile(x: 2, y: 0, z: 10)
        store.insert(try makeMetalTile(active), forKey: active)
        store.insert(try makeMetalTile(retained), forKey: retained)
        store.updateDemandedTiles([active])
        XCTAssertEqual(Set(store.residentTiles().keys), [active, retained])
    }

    func testContainsFollowsResidencyWithoutATrace() throws {
        let store = makeStore()
        let pinned = Tile(x: 1, y: 1, z: 3)
        let ordinary = Tile(x: 1, y: 1, z: 4)
        XCTAssertFalse(store.contains(ordinary))
        store.insert(try makeMetalTile(pinned), forKey: pinned)
        store.insert(try makeMetalTile(ordinary), forKey: ordinary)
        XCTAssertTrue(store.contains(ordinary))

        store.updateDemandedTiles([] as [Tile])
        XCTAssertTrue(store.contains(ordinary), "retained after leaving the demand")
        try fillRetention(store)

        XCTAssertFalse(store.contains(ordinary), "released once the retention filled")
        XCTAssertTrue(store.contains(pinned), "the pinned world cover stays")
    }

    func testWorldCoverUpToZ3IsPinnedAcrossDemandUpdates() throws {
        let store = makeStore()
        let pinned = Tile(x: 1, y: 1, z: 3)
        let ordinary = Tile(x: 1, y: 1, z: 4)
        store.insert(try makeMetalTile(pinned), forKey: pinned)
        store.insert(try makeMetalTile(ordinary), forKey: ordinary)

        store.updateDemandedTiles([] as [Tile])
        try fillRetention(store)

        XCTAssertNotNil(store.tile(forKey: pinned),
                        "The z0-3 world cover must survive leaving demand, retention or not")
        XCTAssertNil(store.tile(forKey: ordinary),
                     "z4 is past the pinned cover and is released once the retention filled")
        XCTAssertFalse(store.retainedTiles.contains(pinned), "the pinned cover never enters the retention")
    }

    func testMemoryWarningReleasesUndemandedWorldCoverAndKeepsDemandedTiles() throws {
        let store = makeStore()
        let demanded = Tile(x: 0, y: 0, z: 2)
        let hidden = Tile(x: 1, y: 0, z: 2)
        let retained = Tile(x: 5, y: 5, z: 10)
        store.insert(try makeMetalTile(demanded), forKey: demanded)
        store.insert(try makeMetalTile(hidden), forKey: hidden)
        store.insert(try makeMetalTile(retained), forKey: retained)
        store.updateDemandedTiles([demanded])
        XCTAssertEqual(store.retainedTiles, [retained])

        store.releaseUndemandedTiles()

        XCTAssertNotNil(store.tile(forKey: demanded),
                        "The demanded set stays so the map does not blank")
        XCTAssertNil(store.tile(forKey: hidden),
                     "Pinned cover outside demand is handed back under pressure")
        XCTAssertNil(store.tile(forKey: retained), "and so is the retention")
        XCTAssertTrue(store.retainedTiles.isEmpty)
    }

    func testRemoveAllClearsEverythingAndAllowsReinsert() throws {
        let store = makeStore()
        let tile = Tile(x: 0, y: 0, z: 0)
        store.insert(try makeMetalTile(tile), forKey: tile)

        store.removeAll()
        XCTAssertNil(store.tile(forKey: tile))
        XCTAssertEqual(store.residentTileCount, 0)
        XCTAssertEqual(store.residentByteCount, 0)

        store.insert(try makeMetalTile(tile), forKey: tile)
        XCTAssertNotNil(store.tile(forKey: tile))
    }

    func testContentVersionBumpsOnInsertButNotOnDemandUpdateRelease() throws {
        let store = makeStore()
        try fillRetention(store)
        let oldest = Tile(x: 1000, y: 1000, z: 12)
        let tile = Tile(x: 9, y: 9, z: 9)
        let initialVersion = store.contentVersion

        store.insert(try makeMetalTile(tile), forKey: tile)
        store.updateDemandedTiles([tile])
        let afterInsert = store.contentVersion
        XCTAssertNotEqual(afterInsert, initialVersion)

        // Leaving the demand retains the tile and evicts the oldest retained one.
        store.updateDemandedTiles([] as [Tile])
        XCTAssertNil(store.tile(forKey: oldest))
        XCTAssertNotNil(store.tile(forKey: tile))
        XCTAssertEqual(store.contentVersion, afterInsert,
                       "A retention release must not re-trigger the demand gate that caused it")
    }

    func testContentVersionBumpsOnMemoryWarningRelease() throws {
        let store = makeStore()
        let tile = Tile(x: 2, y: 1, z: 2)
        store.insert(try makeMetalTile(tile), forKey: tile)
        store.updateDemandedTiles([] as [Tile])
        let beforeWarning = store.contentVersion

        store.releaseUndemandedTiles()

        XCTAssertNotEqual(store.contentVersion, beforeWarning,
                          "Dropping pinned cover changes what a demand pass would find")
    }

    func testResidentByteCountFollowsInsertsAndReleases() throws {
        let store = makeStore(retentionLimit: 2)
        let first = Tile(x: 1, y: 2, z: 10)
        let second = Tile(x: 2, y: 2, z: 10)

        store.insert(try makeMetalTile(first), forKey: first)
        let afterFirst = store.residentByteCount
        XCTAssertGreaterThan(afterFirst, 0)

        store.insert(try makeMetalTile(second), forKey: second)
        XCTAssertGreaterThan(store.residentByteCount, afterFirst)
        XCTAssertEqual(store.residentTileCount, 2)

        store.updateDemandedTiles([] as [Tile])
        XCTAssertEqual(store.residentTileCount, 2, "both retained")
        try fillRetention(store, count: store.retentionLimit)
        XCTAssertEqual(store.residentTileCount, store.retentionLimit)
        XCTAssertNil(store.tile(forKey: first))
        XCTAssertNil(store.tile(forKey: second))
        store.removeAll()
        XCTAssertEqual(store.residentByteCount, 0)
    }

    func testReplacingInsertKeepsOneEntryAndConsistentBytes() throws {
        let store = makeStore()
        let tile = Tile(x: 4, y: 4, z: 11)
        store.insert(try makeMetalTile(tile), forKey: tile)
        let bytes = store.residentByteCount

        store.insert(try makeMetalTile(tile), forKey: tile)

        XCTAssertEqual(store.residentTileCount, 1)
        XCTAssertEqual(store.residentByteCount, bytes)
        XCTAssertNotNil(store.tile(forKey: tile))
    }

    private func makeStore(retentionLimit: Int = TileWorkingSetStore.retentionLimit) -> TileWorkingSetStore {
        TileWorkingSetStore(tileTraceRecorder: TileTraceRecorder(), retentionLimit: retentionLimit)
    }

    private func makeMetalTile(_ tile: Tile) throws -> MetalTile {
        MetalTile(tile: tile, tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
    }
}
