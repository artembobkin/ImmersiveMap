// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class DebugOverlayTilesStatusRowTests: XCTestCase {
    func testALiveRowShowsItsAgeOnceItIsOld() {
        let tile = Tile(x: 77, y: 40, z: 7)
        let young = TileLoadingStatusTileSnapshot(tile: tile,
                                                  status: .parsing,
                                                  progress: 0.7,
                                                  detail: "parse",
                                                  stageAgeSeconds: 1)
        let old = TileLoadingStatusTileSnapshot(tile: tile,
                                                status: .parsing,
                                                progress: 0.7,
                                                detail: "parse",
                                                stageAgeSeconds: 12)

        XCTAssertEqual(DebugOverlayTilesStatusRow.tile(young, isExpanded: false, canExpand: false).text,
                       "  z7/77/40 parse")
        XCTAssertEqual(DebugOverlayTilesStatusRow.tile(old, isExpanded: false, canExpand: false).text,
                       "  z7/77/40 parse 12s")
    }

    func testAFinishedRowNeverShowsAnAge() {
        let displayed = TileLoadingStatusTileSnapshot(tile: Tile(x: 0, y: 0, z: 0),
                                                      status: .ready,
                                                      progress: 1,
                                                      detail: "displayed",
                                                      stageAgeSeconds: 0)

        XCTAssertEqual(DebugOverlayTilesStatusRow.tile(displayed, isExpanded: false, canExpand: true).text,
                       "▸ z0/0/0 displayed")
    }
}
