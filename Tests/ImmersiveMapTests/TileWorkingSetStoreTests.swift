// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

/// The working-set contract: residency equals the demanded set plus the
/// pinned world cover, a tile is released the moment demand stops naming it,
/// and nothing survives on recency.
final class TileWorkingSetStoreTests: XCTestCase {
    func testDemandedTileStaysResidentAcrossDemandUpdates() throws {
        let store = makeStore()
        let tile = Tile(x: 5, y: 6, z: 10)
        store.insert(try makeMetalTile(tile), forKey: tile)

        store.updateDemandedTiles([tile])
        store.updateDemandedTiles([tile])

        XCTAssertNotNil(store.tile(forKey: tile))
    }

    func testTileLeavingTheDemandedSetIsReleasedImmediately() throws {
        let store = makeStore()
        let staying = Tile(x: 1, y: 0, z: 10)
        let leaving = Tile(x: 2, y: 0, z: 10)
        store.insert(try makeMetalTile(staying), forKey: staying)
        store.insert(try makeMetalTile(leaving), forKey: leaving)

        store.updateDemandedTiles([staying])

        XCTAssertNotNil(store.tile(forKey: staying))
        XCTAssertNil(store.tile(forKey: leaving),
                     "A tile outside the demanded set must not survive on recency")
    }

    func testInsertOutsideDemandSurvivesUntilTheNextDemandUpdate() throws {
        // Offscreen harnesses parse tiles before any frame has demanded them;
        // the store must hold such a tile until demand actually speaks.
        let store = makeStore()
        let tile = Tile(x: 3, y: 3, z: 12)

        store.insert(try makeMetalTile(tile), forKey: tile)
        XCTAssertNotNil(store.tile(forKey: tile))

        store.updateDemandedTiles([])
        XCTAssertNil(store.tile(forKey: tile))
    }

    func testWorldCoverUpToZ3IsPinnedAcrossDemandUpdates() throws {
        let store = makeStore()
        let pinned = Tile(x: 1, y: 1, z: 3)
        let ordinary = Tile(x: 1, y: 1, z: 4)
        store.insert(try makeMetalTile(pinned), forKey: pinned)
        store.insert(try makeMetalTile(ordinary), forKey: ordinary)

        store.updateDemandedTiles([])

        XCTAssertNotNil(store.tile(forKey: pinned),
                        "The z0-3 world cover must survive leaving demand")
        XCTAssertNil(store.tile(forKey: ordinary),
                     "z4 is past the pinned cover and must be released")
    }

    func testMemoryWarningReleasesUndemandedWorldCoverAndKeepsDemandedTiles() throws {
        let store = makeStore()
        let demanded = Tile(x: 0, y: 0, z: 2)
        let hidden = Tile(x: 1, y: 0, z: 2)
        store.insert(try makeMetalTile(demanded), forKey: demanded)
        store.insert(try makeMetalTile(hidden), forKey: hidden)
        store.updateDemandedTiles([demanded])

        store.releaseUndemandedTiles()

        XCTAssertNotNil(store.tile(forKey: demanded),
                        "The demanded set stays so the map does not blank")
        XCTAssertNil(store.tile(forKey: hidden),
                     "Pinned cover outside demand is handed back under pressure")
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
        let tile = Tile(x: 9, y: 9, z: 9)
        let initialVersion = store.contentVersion

        store.insert(try makeMetalTile(tile), forKey: tile)
        let afterInsert = store.contentVersion
        XCTAssertNotEqual(afterInsert, initialVersion)

        store.updateDemandedTiles([])
        XCTAssertNil(store.tile(forKey: tile))
        XCTAssertEqual(store.contentVersion, afterInsert,
                       "A left-demand release must not re-trigger the demand gate that caused it")
    }

    func testContentVersionBumpsOnMemoryWarningRelease() throws {
        let store = makeStore()
        let tile = Tile(x: 2, y: 1, z: 2)
        store.insert(try makeMetalTile(tile), forKey: tile)
        store.updateDemandedTiles([])
        let beforeWarning = store.contentVersion

        store.releaseUndemandedTiles()

        XCTAssertNotEqual(store.contentVersion, beforeWarning,
                          "Dropping pinned cover changes what a demand pass would find")
    }

    func testResidentByteCountFollowsInsertsAndReleases() throws {
        let store = makeStore()
        let first = Tile(x: 1, y: 2, z: 10)
        let second = Tile(x: 2, y: 2, z: 10)

        store.insert(try makeMetalTile(first), forKey: first)
        let afterFirst = store.residentByteCount
        XCTAssertGreaterThan(afterFirst, 0)

        store.insert(try makeMetalTile(second), forKey: second)
        XCTAssertGreaterThan(store.residentByteCount, afterFirst)
        XCTAssertEqual(store.residentTileCount, 2)

        store.updateDemandedTiles([])
        XCTAssertEqual(store.residentTileCount, 0)
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

    private func makeStore() -> TileWorkingSetStore {
        TileWorkingSetStore(tileTraceRecorder: TileTraceRecorder())
    }

    private func makeMetalTile(_ tile: Tile) throws -> MetalTile {
        MetalTile(tile: tile, tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
    }
}
