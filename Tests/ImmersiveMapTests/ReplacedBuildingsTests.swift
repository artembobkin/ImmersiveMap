// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Which buildings a map tile leaves out for the models: the ids listed for
/// the tile's own zoom, because an id names a building only within a zoom.
final class ReplacedBuildingsTests: XCTestCase {
    func testAMapTileTakesTheListOfItsOwnZoom() {
        let replaced = ReplacedBuildings(byMapTileZoom: [14: [100], 15: [1, 2]])

        XCTAssertEqual(replaced.ids(forMapTileZoom: 14), [100])
        XCTAssertEqual(replaced.ids(forMapTileZoom: 15), [1, 2])
    }

    /// The tiles below the archive's deepest carry the same one feature
    /// per element, so they take the deepest list.
    func testATileDeeperThanEveryListTakesTheDeepest() {
        let replaced = ReplacedBuildings(byMapTileZoom: [14: [100], 15: [1, 2]])

        XCTAssertEqual(replaced.ids(forMapTileZoom: 16), [1, 2])
    }

    /// The ids of a shallower zoom are groups the deeper lists know
    /// nothing of: a tile with no list of its own hides nothing.
    func testAShallowerTileWithNoListOfItsOwnTakesNone() {
        let replaced = ReplacedBuildings(byMapTileZoom: [15: [1, 2]])

        XCTAssertTrue(replaced.ids(forMapTileZoom: 14).isEmpty)
        XCTAssertTrue(ReplacedBuildings.none.ids(forMapTileZoom: 15).isEmpty)
    }

    func testTheBuildingsOfEveryZoomAreAddedToEachList() {
        let replaced = ReplacedBuildings(atEveryZoom: [9], byMapTileZoom: [15: [1]])

        XCTAssertEqual(replaced.ids(forMapTileZoom: 15), [1, 9])
        XCTAssertEqual(replaced.ids(forMapTileZoom: 14), [9])
    }

    func testTheListsOfSeveralModelTilesAddUpZoomByZoom() {
        var replaced = ReplacedBuildings.none
        XCTAssertTrue(replaced.isEmpty)

        replaced.formUnion(byMapTileZoom: [14: [100], 15: [1]])
        replaced.formUnion(byMapTileZoom: [15: [2]])

        XCTAssertEqual(replaced, ReplacedBuildings(byMapTileZoom: [14: [100], 15: [1, 2]]))
        XCTAssertFalse(replaced.isEmpty)
        XCTAssertTrue(ReplacedBuildings(byMapTileZoom: [15: []]).isEmpty)
    }
}
