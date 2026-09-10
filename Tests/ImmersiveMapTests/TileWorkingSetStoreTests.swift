// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

/// The working-set contract: residency is the demanded set, the pinned
/// world cover, and the tiles that stand in for a demanded tile that has
/// not arrived (its resident descendants within the stand-in depth, its
/// finest resident ancestor). Nothing else survives a demand update, and
/// nothing is remembered between two of them.
final class TileWorkingSetStoreTests: XCTestCase {
    func testDemandedTileStaysResidentAcrossDemandUpdates() throws {
        let store = makeStore()
        let tile = Tile(x: 5, y: 6, z: 10)
        store.insert(try makeMetalTile(tile), forKey: tile)

        store.updateDemandedTiles([tile])
        store.updateDemandedTiles([tile])

        XCTAssertNotNil(store.tile(forKey: tile))
    }

    func testATileLeavingTheDemandWithNothingToStandInForIsReleasedAtOnce() throws {
        let store = makeStore()
        let staying = Tile(x: 1, y: 0, z: 10)
        let leaving = Tile(x: 2, y: 0, z: 10)
        store.insert(try makeMetalTile(staying), forKey: staying)
        store.insert(try makeMetalTile(leaving), forKey: leaving)

        store.updateDemandedTiles([staying])

        XCTAssertNotNil(store.tile(forKey: staying))
        XCTAssertNil(store.tile(forKey: leaving), "No retention: a tile the demand does not name and nothing needs goes")
        XCTAssertEqual(store.residentTileCount, 1)
    }

    func testInsertOutsideDemandIsHeldUntilDemandSpeaks() throws {
        // Offscreen harnesses parse tiles before any frame has demanded them;
        // the store must hold such a tile until demand actually speaks.
        let store = makeStore()
        let tile = Tile(x: 3, y: 3, z: 12)

        store.insert(try makeMetalTile(tile), forKey: tile)
        XCTAssertNotNil(store.tile(forKey: tile))

        store.updateDemandedTiles([] as [Tile])
        XCTAssertNil(store.tile(forKey: tile))
    }

    /// A zoom-out: the z16 tiles on screen stay while their z14 parent
    /// loads, and go the moment it is resident.
    func testDescendantsOfALoadingTargetStayUntilItLands() throws {
        let store = makeStore()
        let parent = Tile(x: 10, y: 10, z: 14)
        let children = (0 ..< 4).map { Tile(x: 40 + $0 % 2, y: 40 + $0 / 2, z: 16) }
        let stranger = Tile(x: 90, y: 90, z: 16)
        for tile in children + [stranger] {
            store.insert(try makeMetalTile(tile), forKey: tile)
        }
        store.updateDemandedTiles(children + [stranger])

        store.updateDemandedTiles([parent])
        for child in children {
            XCTAssertNotNil(store.tile(forKey: child), "\(child) stands in for the loading parent")
        }
        XCTAssertNil(store.tile(forKey: stranger), "a tile under no loading target goes")

        store.insert(try makeMetalTile(parent), forKey: parent)
        store.updateDemandedTiles([parent])
        for child in children {
            XCTAssertNil(store.tile(forKey: child), "\(child) is released once the parent is resident")
        }
        XCTAssertNotNil(store.tile(forKey: parent))
    }

    /// A descendant stands in at any depth: a long zoom-out keeps the block
    /// the camera was looking at until the far ancestor lands.
    func testDescendantsStayAtAnyDepth() throws {
        let store = makeStore()
        let target = Tile(x: 1, y: 1, z: 5)
        let deep = Tile(x: 1 << 11, y: 1 << 11, z: 16)
        let unrelated = Tile(x: 3 << 11, y: 1 << 11, z: 16)
        store.insert(try makeMetalTile(deep), forKey: deep)
        store.insert(try makeMetalTile(unrelated), forKey: unrelated)

        store.updateDemandedTiles([target])

        XCTAssertNotNil(store.tile(forKey: deep))
        XCTAssertNil(store.tile(forKey: unrelated), "under no loading target, it goes")
        store.insert(try makeMetalTile(target), forKey: target)
        store.updateDemandedTiles([target])
        XCTAssertNil(store.tile(forKey: deep), "released once the ancestor lands")
    }

    /// A zoom-in: the z14 tile on screen stays while its z16 children load,
    /// and goes once every child that is demanded has landed.
    func testTheFinestResidentAncestorOfALoadingTargetStaysUntilItsChildrenLand() throws {
        let store = makeStore()
        let parent = Tile(x: 10, y: 10, z: 14)
        let grandparent = Tile(x: 5, y: 5, z: 13)
        let children = (0 ..< 4).map { Tile(x: 40 + $0 % 2, y: 40 + $0 / 2, z: 16) }
        store.insert(try makeMetalTile(parent), forKey: parent)
        store.insert(try makeMetalTile(grandparent), forKey: grandparent)
        store.updateDemandedTiles([parent, grandparent])

        store.updateDemandedTiles(children)
        XCTAssertNotNil(store.tile(forKey: parent), "the finest resident ancestor stands in")
        XCTAssertNil(store.tile(forKey: grandparent), "a coarser ancestor is not drawn and not kept")

        for child in children.dropLast() {
            store.insert(try makeMetalTile(child), forKey: child)
        }
        store.updateDemandedTiles(children)
        XCTAssertNotNil(store.tile(forKey: parent), "one child still loading keeps the parent")

        store.insert(try makeMetalTile(children.last!), forKey: children.last!)
        store.updateDemandedTiles(children)
        XCTAssertNil(store.tile(forKey: parent), "every child resident, the parent goes")
    }

    func testAStandInIsReleasedWhenItsTargetLeavesTheDemand() throws {
        let store = makeStore()
        let parent = Tile(x: 10, y: 10, z: 14)
        let child = Tile(x: 40, y: 40, z: 16)
        store.insert(try makeMetalTile(child), forKey: child)
        store.updateDemandedTiles([parent])
        XCTAssertNotNil(store.tile(forKey: child))

        store.updateDemandedTiles([Tile(x: 11, y: 11, z: 14)])
        XCTAssertNil(store.tile(forKey: child), "the camera moved on: nothing needs the child any more")
    }

    func testNothingIsRememberedBetweenDemandUpdates() throws {
        // The same demand given twice releases the same tiles: no queue, no
        // history, only the set and what is resident.
        let store = makeStore()
        let target = Tile(x: 10, y: 10, z: 14)
        let child = Tile(x: 40, y: 40, z: 16)
        store.insert(try makeMetalTile(child), forKey: child)
        store.updateDemandedTiles([target])
        store.updateDemandedTiles([target])
        XCTAssertNotNil(store.tile(forKey: child))
        store.insert(try makeMetalTile(target), forKey: target)
        store.updateDemandedTiles([target])
        XCTAssertNil(store.tile(forKey: child))
        XCTAssertEqual(store.residentTileCount, 1)
    }

    func testResidentTilesListsTheStandInsToo() throws {
        let store = makeStore()
        let active = Tile(x: 1, y: 0, z: 10)
        let standIn = Tile(x: 2, y: 0, z: 12)
        store.insert(try makeMetalTile(active), forKey: active)
        store.insert(try makeMetalTile(standIn), forKey: standIn)
        store.updateDemandedTiles([active, Tile(x: 1, y: 0, z: 11)])
        XCTAssertEqual(Set(store.residentTiles().keys), [active, standIn])
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

        XCTAssertFalse(store.contains(ordinary), "released on leaving the demand")
        XCTAssertTrue(store.contains(pinned), "the pinned world cover stays")
    }

    func testWorldCoverUpToZ3IsPinnedAcrossDemandUpdates() throws {
        let store = makeStore()
        let pinned = Tile(x: 1, y: 1, z: 3)
        let ordinary = Tile(x: 1, y: 1, z: 4)
        store.insert(try makeMetalTile(pinned), forKey: pinned)
        store.insert(try makeMetalTile(ordinary), forKey: ordinary)

        store.updateDemandedTiles([] as [Tile])

        XCTAssertNotNil(store.tile(forKey: pinned),
                        "The z0-3 world cover must survive leaving demand")
        XCTAssertNil(store.tile(forKey: ordinary),
                     "z4 is past the pinned cover and is released")
    }

    func testThePinnedCoverIsNeverAStandInThatKeepsAnything() throws {
        // A loading z4 target has only pinned ancestors: nothing to keep,
        // nothing to release.
        let store = makeStore()
        let pinned = Tile(x: 0, y: 0, z: 3)
        store.insert(try makeMetalTile(pinned), forKey: pinned)
        store.updateDemandedTiles([Tile(x: 0, y: 0, z: 4)])
        XCTAssertNotNil(store.tile(forKey: pinned))
        XCTAssertEqual(store.residentTileCount, 1)
    }

    func testMemoryWarningReleasesUndemandedWorldCoverAndKeepsDemandedTiles() throws {
        let store = makeStore()
        let demanded = Tile(x: 0, y: 0, z: 2)
        let hidden = Tile(x: 1, y: 0, z: 2)
        let loading = Tile(x: 10, y: 10, z: 14)
        let standIn = Tile(x: 40, y: 40, z: 16)
        store.insert(try makeMetalTile(demanded), forKey: demanded)
        store.insert(try makeMetalTile(hidden), forKey: hidden)
        store.insert(try makeMetalTile(standIn), forKey: standIn)
        store.updateDemandedTiles([demanded, loading])
        XCTAssertNotNil(store.tile(forKey: standIn))

        store.releaseUndemandedTiles()

        XCTAssertNotNil(store.tile(forKey: demanded),
                        "The demanded set stays so the map does not blank")
        XCTAssertNil(store.tile(forKey: hidden),
                     "Pinned cover outside demand is handed back under pressure")
        XCTAssertNotNil(store.tile(forKey: standIn), "what the frame draws under a loading target stays")
    }

    func testMemoryWarningKeepsACoverTileStandingInOnTheSphere() throws {
        // The sphere has no backdrop: a loading z5 target is drawn from its
        // finest resident ancestor, the pinned z3 here, which a warning
        // therefore keeps; a cover tile under no loading target goes.
        let store = makeStore()
        let standingIn = Tile(x: 4, y: 4, z: 3)
        let idle = Tile(x: 0, y: 0, z: 3)
        store.insert(try makeMetalTile(standingIn), forKey: standingIn)
        store.insert(try makeMetalTile(idle), forKey: idle)
        store.updateDemandedTiles([Tile(x: 16, y: 16, z: 5)])

        store.releaseUndemandedTiles()

        XCTAssertNotNil(store.tile(forKey: standingIn))
        XCTAssertNil(store.tile(forKey: idle))
    }

    func testMemoryWarningReleasesWhatNoFrameNeeds() throws {
        let store = makeStore()
        let orphan = Tile(x: 7, y: 7, z: 12)
        store.insert(try makeMetalTile(orphan), forKey: orphan)
        let before = store.contentVersion
        store.releaseUndemandedTiles()
        XCTAssertNil(store.tile(forKey: orphan), "a tile no demand has spoken for goes")
        XCTAssertNotEqual(store.contentVersion, before)
        store.releaseUndemandedTiles()
        XCTAssertEqual(store.residentTileCount, 0)
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
        let leaving = Tile(x: 1000, y: 1000, z: 12)
        let tile = Tile(x: 9, y: 9, z: 9)
        store.insert(try makeMetalTile(leaving), forKey: leaving)
        store.updateDemandedTiles([leaving])
        let initialVersion = store.contentVersion

        store.insert(try makeMetalTile(tile), forKey: tile)
        store.updateDemandedTiles([tile, leaving])
        let afterInsert = store.contentVersion
        XCTAssertNotEqual(afterInsert, initialVersion)

        store.updateDemandedTiles([tile])
        XCTAssertNil(store.tile(forKey: leaving))
        XCTAssertNotNil(store.tile(forKey: tile))
        XCTAssertEqual(store.contentVersion, afterInsert,
                       "A demand-update release must not re-trigger the demand gate that caused it")
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
        let store = makeStore()
        let first = Tile(x: 1, y: 2, z: 10)
        let second = Tile(x: 2, y: 2, z: 10)

        store.insert(try makeMetalTile(first), forKey: first)
        let afterFirst = store.residentByteCount
        XCTAssertGreaterThan(afterFirst, 0)

        store.insert(try makeMetalTile(second), forKey: second)
        XCTAssertGreaterThan(store.residentByteCount, afterFirst)
        XCTAssertEqual(store.residentTileCount, 2)

        store.updateDemandedTiles([first])
        XCTAssertEqual(store.residentByteCount, afterFirst, "the released tile's bytes are handed back")
        store.updateDemandedTiles([] as [Tile])
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
