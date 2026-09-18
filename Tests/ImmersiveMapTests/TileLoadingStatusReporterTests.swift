// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileLoadingStatusReporterTests: XCTestCase {
    func testALiveRowGrowsOldUntilItsDetailChanges() {
        var now: TimeInterval = 100
        let reporter = TileLoadingStatusReporter(now: { now })
        let tile = Tile(x: 77, y: 40, z: 7)
        reporter.recordDemand(input: 1, deduplicated: 1, tiles: [tile])
        reporter.recordLoadScheduled(tile: tile)
        reporter.recordLoadStarted(tile: tile)
        reporter.recordParsingStarted(tile: tile)

        now = 103.4
        XCTAssertEqual(reporter.snapshot().tiles.first?.stageAgeSeconds, 3)

        // A new detail starts a new age.
        reporter.recordParsingSucceeded(tile: tile)
        XCTAssertEqual(reporter.snapshot().tiles.first?.detail, "materialize")
        XCTAssertEqual(reporter.snapshot().tiles.first?.stageAgeSeconds, 0)
        now = 105
        XCTAssertEqual(reporter.snapshot().tiles.first?.stageAgeSeconds, 1)

        // A finished row has no age: it is not waiting for anything.
        reporter.recordLoadCompleted(tile: tile)
        now = 200
        XCTAssertEqual(reporter.snapshot().tiles.first?.status, .ready)
        XCTAssertEqual(reporter.snapshot().tiles.first?.stageAgeSeconds, 0)
    }

    func testAStalledLoadClosesItsPhaseAndFails() {
        let reporter = TileLoadingStatusReporter()
        let tile = Tile(x: 1, y: 1, z: 4)
        reporter.recordDemand(input: 1, deduplicated: 1, tiles: [tile])
        reporter.recordLoadScheduled(tile: tile)
        reporter.recordLoadStarted(tile: tile)
        reporter.recordDiskStarted(tile: tile)
        XCTAssertEqual(reporter.snapshot().disk.inFlight, 1)
        XCTAssertEqual(reporter.snapshot().activeLoads, 1)

        reporter.recordLoadStalled(tile: tile, stage: "disk")

        let snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.disk.inFlight, 0)
        XCTAssertEqual(snapshot.activeLoads, 0)
        XCTAssertEqual(snapshot.totalFailed, 1)
        XCTAssertEqual(snapshot.latestFailure, "stalled in disk")
        XCTAssertNil(snapshot.latestDiskTile)
        let row = snapshot.tiles.first
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.detail, "stalled in disk")
        XCTAssertEqual(row?.preparationStages.map(\.name), ["disk"], "The phase it stalled in is closed, with its duration")
    }

    func testAnEndedLoadDemotesOnlyALiveRow() {
        let reporter = TileLoadingStatusReporter()
        let live = Tile(x: 1, y: 1, z: 4)
        let done = Tile(x: 2, y: 1, z: 4)
        reporter.recordDemand(input: 2, deduplicated: 2, tiles: [live, done])
        for tile in [live, done] {
            reporter.recordLoadScheduled(tile: tile)
            reporter.recordLoadStarted(tile: tile)
            reporter.recordNetworkStarted(tile: tile)
        }
        reporter.recordNetworkSucceeded(tile: done, bytes: 10)
        reporter.recordLoadCompleted(tile: done)

        reporter.recordLoadEnded(tile: live)
        reporter.recordLoadEnded(tile: done)

        let snapshot = reporter.snapshot()
        let liveRow = snapshot.tiles.first { $0.tile == live }
        XCTAssertEqual(liveRow?.status, .failed)
        XCTAssertEqual(liveRow?.detail, "ended in network")
        XCTAssertEqual(snapshot.network.inFlight, 0)
        XCTAssertEqual(snapshot.activeLoads, 0)
        let doneRow = snapshot.tiles.first { $0.tile == done }
        XCTAssertEqual(doneRow?.status, .ready)
        XCTAssertEqual(doneRow?.detail, "ready")
    }
}
