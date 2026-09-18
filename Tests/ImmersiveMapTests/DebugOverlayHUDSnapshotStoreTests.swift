// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class DebugOverlayHUDSnapshotStoreTests: XCTestCase {
    func testConsumeLatestReturnsOnlyNewPublishedVersions() {
        let store = DebugOverlayHUDSnapshotStore()
        let snapshot = makeSnapshot(zoom: "z: 4.62")

        XCTAssertNil(store.consumeLatest(after: 0))

        let firstVersion = store.publish(snapshot)
        let firstValue = store.consumeLatest(after: 0)

        XCTAssertEqual(firstValue?.version, firstVersion)
        XCTAssertEqual(firstValue?.snapshot, snapshot)
        XCTAssertNil(store.consumeLatest(after: firstVersion))
    }

    func testNilSnapshotIsPublishedAsAStoreVersion() {
        let store = DebugOverlayHUDSnapshotStore()

        let version = store.publish(nil)
        let value = store.consumeLatest(after: 0)

        XCTAssertEqual(value?.version, version)
        XCTAssertNil(value?.snapshot)
    }

    func testTheAttachedProviderAnswersBetweenFramesUntilDetached() {
        let store = DebugOverlayHUDSnapshotStore()
        XCTAssertNil(store.currentTileLoadingStatus())

        let reporter = TileLoadingStatusReporter()
        let tile = Tile(x: 1, y: 1, z: 4)
        reporter.recordDemand(input: 1, deduplicated: 1, tiles: [tile])
        reporter.recordLoadScheduled(tile: tile)
        store.attachTileLoadingStatus(provider: { reporter.snapshot() })

        XCTAssertEqual(store.currentTileLoadingStatus()?.tiles.map(\.tile), [tile])

        store.attachTileLoadingStatus(provider: nil)
        XCTAssertNil(store.currentTileLoadingStatus())
    }

    func testReplacingTheTileListKeepsTheFrameAndIsEqualWhenNothingMoved() {
        let snapshot = makeSnapshot(zoom: "z: 4.62")
        let reporter = TileLoadingStatusReporter()

        XCTAssertEqual(snapshot.replacingTileLoadingStatus(reporter.snapshot()), snapshot)

        let tile = Tile(x: 1, y: 1, z: 4)
        reporter.recordDemand(input: 1, deduplicated: 1, tiles: [tile])
        reporter.recordLoadScheduled(tile: tile)
        let refreshed = snapshot.replacingTileLoadingStatus(reporter.snapshot())

        XCTAssertNotEqual(refreshed, snapshot)
        XCTAssertEqual(refreshed.coordinateLines, snapshot.coordinateLines)
        XCTAssertEqual(refreshed.diagnosticsLines, snapshot.diagnosticsLines)
        XCTAssertEqual(refreshed.tileLoadingStatusTiles.map(\.tile), [tile])
        XCTAssertFalse(refreshed.tileLoadingStatusLines.isEmpty)
    }

    private func makeSnapshot(zoom: String) -> DebugOverlayHUDSnapshot {
        let settings = ImmersiveMapSettings.default.debug
        return DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: zoom, latLon: "lat: 55.756 lon: 37.617"),
            diagnosticsLines: ["frame:1 dt:16.67ms fps:60.0"],
            tileLoadingStatusLines: [],
            tileLoadingStatusTiles: [],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        )
    }
}
