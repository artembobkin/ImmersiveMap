// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The tile cards of the debug HUD (`DebugOverlayTileCard`): one card per
/// tile with everything the list knows of it, the deepest zoom first.
final class DebugOverlayTileCardTests: XCTestCase {
    func testALiveCardShowsItsAgeOnceItIsOld() {
        let tile = Tile(x: 77, y: 40, z: 7)
        let young = TileLoadingStatusTileSnapshot(tile: tile, status: .parsing, progress: 0.7, detail: "parse", stageAgeSeconds: 1)
        let old = TileLoadingStatusTileSnapshot(tile: tile, status: .parsing, progress: 0.7, detail: "parse", stageAgeSeconds: 12)

        XCTAssertEqual(DebugOverlayTileCard(young).headline, "z7/77/40 parse")
        XCTAssertEqual(DebugOverlayTileCard(old).headline, "z7/77/40 parse 12s")
        XCTAssertEqual(DebugOverlayTileCard(old).lines, ["z7/77/40 parse 12s"], "No stage yet: one line")
    }

    func testAFinishedCardNeverShowsAnAge() {
        let displayed = TileLoadingStatusTileSnapshot(tile: Tile(x: 0, y: 0, z: 0), status: .ready, progress: 1, detail: "displayed")
        XCTAssertEqual(DebugOverlayTileCard(displayed).statusText, "displayed")
        let bare = TileLoadingStatusTileSnapshot(tile: Tile(x: 0, y: 0, z: 0), status: .loading, progress: 0.2, detail: "")
        XCTAssertEqual(DebugOverlayTileCard(bare).statusText, "network", "Without a detail, the status")
    }

    func testTheStagesAndTheDearestLayersAreOnTheCard() {
        let snapshot = TileLoadingStatusTileSnapshot(
            tile: Tile(x: 78, y: 39, z: 7),
            status: .ready,
            progress: 1,
            detail: "ready",
            preparationStages: [
                TilePreparationStageSnapshot(name: "disk", duration: 0.003),
                TilePreparationStageSnapshot(name: "parse",
                                             duration: 0.062,
                                             layerTimings: [
                                                 TileParseLayerTiming(layerName: "roads", duration: 0.007),
                                                 TileParseLayerTiming(layerName: "landuse", duration: 0.046),
                                                 TileParseLayerTiming(layerName: "places", duration: 0.001),
                                                 TileParseLayerTiming(layerName: "water", duration: 0.002)
                                             ]),
                TilePreparationStageSnapshot(name: "ready", duration: nil)
            ])
        let card = DebugOverlayTileCard(snapshot)
        XCTAssertEqual(card.stagesText, "disk 3ms · parse 62ms · ready", "Every stage in order, a live one without a time")
        XCTAssertEqual(card.layersText, "landuse 46ms · roads 7ms · water 2ms", "The three dearest layers, dearest first")
        XCTAssertEqual(card.lines.count, 3)
    }

    func testTheCardsComeDeepestZoomFirstAndByAddressWithinAZoom() {
        func snapshot(_ x: Int, _ y: Int, _ z: Int) -> TileLoadingStatusTileSnapshot {
            TileLoadingStatusTileSnapshot(tile: Tile(x: x, y: y, z: z), status: .ready, progress: 1, detail: "displayed")
        }
        let cards = DebugOverlayTileCard.cards(for: [snapshot(4, 3, 3), snapshot(67, 46, 7), snapshot(33, 23, 6), snapshot(67, 45, 7), snapshot(66, 45, 7)])
        XCTAssertEqual(cards.map(\.title), ["z7/66/45", "z7/67/45", "z7/67/46", "z6/33/23", "z3/4/3"])
    }
}
