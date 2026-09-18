// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import XCTest

final class ImmersiveMapNeedsTileTests: XCTestCase {
    func testRequestDoesNotCollectTileLoadingStatusWhenReporterIsAbsent() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: nil)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)

        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(didPrepare)
        pipeline.completePrepare(tile)
        let didMaterialize = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(didMaterialize)
        pipeline.completeMaterialize(tile, result: true)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(loader.tileLoadingStatusSnapshotForTesting)
    }

    func testRequestCollectsNetworkAndParseProgressWhenReporterIsPresent() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)
        guard let loadingTile = reporter.snapshot().tiles.first else {
            XCTFail("Expected loading tile status")
            return
        }
        XCTAssertEqual(loadingTile.status, .loading)
        XCTAssertEqual(loadingTile.progress, 0.35, accuracy: 0.001)
        XCTAssertEqual(reporter.snapshot().network.inFlight, 1)
        XCTAssertEqual(reporter.snapshot().disk.failed, 1)

        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(didPrepare)
        XCTAssertEqual(reporter.snapshot().network.completed, 1)
        XCTAssertEqual(reporter.snapshot().parsing.inFlight, 1)
        guard let parsingTile = reporter.snapshot().tiles.first else {
            XCTFail("Expected parsing tile status")
            return
        }
        XCTAssertEqual(parsingTile.status, .parsing)
        XCTAssertEqual(parsingTile.progress, 0.7, accuracy: 0.001)

        pipeline.completePrepare(tile)
        let didMaterialize = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(didMaterialize)
        pipeline.completeMaterialize(tile, result: true)

        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.parsing.completed, 1)
        XCTAssertEqual(snapshot.totalCompleted, 1)
        XCTAssertNil(snapshot.latestNetworkTile)
        XCTAssertNil(snapshot.latestParsingTile)
        guard let readyTile = snapshot.tiles.first else {
            XCTFail("Expected ready tile status")
            return
        }
        XCTAssertEqual(readyTile.status, .ready)
        XCTAssertEqual(readyTile.progress, 1, accuracy: 0.001)
    }

    func testTileLoadingSnapshotReportsLatestParseLayerTimings() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 78, y: 39, z: 7)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)
        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(didPrepare)
        pipeline.completePrepare(tile, timings: [
            TileParseLayerTiming(layerName: "streets", duration: 0.003),
            TileParseLayerTiming(layerName: "land", duration: 0.127),
            TileParseLayerTiming(layerName: "water_polygons", duration: 0.041)
        ])
        let didMaterialize = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(didMaterialize)
        pipeline.completeMaterialize(tile, result: true)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(reporter.snapshot().lines.contains(
            "parse layers z7/78/39: land 127ms, water_polygons 41ms, streets 3ms"
        ))
    }

    func testTileLoadingSnapshotReportsPerTilePreparationStagesAndParseLayers() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        var now = 1.0
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter(now: { now })
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 78, y: 39, z: 7)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)

        now = 1.100
        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(didPrepare)

        now = 1.350
        pipeline.completePrepare(tile, timings: [
            TileParseLayerTiming(layerName: "streets", duration: 0.003),
            TileParseLayerTiming(layerName: "land", duration: 0.127),
            TileParseLayerTiming(layerName: "water_polygons", duration: 0.041)
        ])
        let didMaterialize = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(didMaterialize)

        now = 1.380
        pipeline.completeMaterialize(tile, result: true)

        try? await Task.sleep(nanoseconds: 100_000_000)

        let stages = try? XCTUnwrap(reporter.snapshot().tiles.first?.preparationStages)
        XCTAssertEqual(stages?.map(\.name), ["disk", "network", "parse", "materialize", "ready"])
        XCTAssertEqual(stages?[1].duration ?? 0, 0.100, accuracy: 0.001)
        XCTAssertEqual(stages?[2].duration ?? 0, 0.250, accuracy: 0.001)
        XCTAssertEqual(stages?[3].duration ?? 0, 0.030, accuracy: 0.001)
        XCTAssertEqual(stages?[2].layerTimings.map(\.layerName), ["land", "water_polygons", "streets"])
    }

    func testDisplayedTileKeepsRecentPreparationStagesAfterDemandPrunesReadyRecord() {
        var now = 1.0
        let reporter = TileLoadingStatusReporter(now: { now })
        let tile = Tile(x: 11, y: 6, z: 4)

        reporter.recordDemand(input: 1, deduplicated: 1, tiles: [tile])
        reporter.recordNetworkStarted(tile: tile)
        now = 1.100
        reporter.recordNetworkSucceeded(tile: tile, bytes: 1024)
        reporter.recordParsingStarted(tile: tile)
        now = 1.350
        reporter.recordParsingSucceeded(tile: tile, layerTimings: [
            TileParseLayerTiming(layerName: "boundaries", duration: 0.244),
            TileParseLayerTiming(layerName: "ocean", duration: 0.044)
        ])
        reporter.recordMaterializationStarted(tile: tile)
        now = 1.380
        reporter.recordMaterializationSucceeded(tile: tile)
        reporter.recordDemand(input: 0, deduplicated: 0, tiles: [])
        reporter.recordLoadCompleted(tile: tile)

        XCTAssertFalse(reporter.snapshot().tiles.contains { $0.tile == tile })

        reporter.recordDisplayedTiles([tile])

        guard let stages = reporter.snapshot().tiles.first?.preparationStages else {
            XCTFail("Expected displayed tile stages")
            return
        }
        XCTAssertEqual(stages.map(\.name), ["network", "parse", "materialize", "ready"])
        XCTAssertEqual(stages[1].layerTimings.map(\.layerName), ["boundaries", "ocean"])
    }

    func testTileLoadingSnapshotKeepsOnlyCurrentDemandAndActiveWork() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 2
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let staleReadyTile = Tile(x: 1, y: 1, z: 4)
        let staleLoadingTile = Tile(x: 2, y: 1, z: 4)
        let currentTile = Tile(x: 3, y: 1, z: 4)

        loader.request(tiles: [staleReadyTile])
        let staleReadyStarted = await pipeline.waitUntilStarted(staleReadyTile)
        XCTAssertTrue(staleReadyStarted)
        pipeline.completeDownload(staleReadyTile, result: .success(Data([1, 2, 3]), etag: nil))
        let staleReadyPrepared = await pipeline.waitUntilPrepared(staleReadyTile)
        XCTAssertTrue(staleReadyPrepared)
        pipeline.completePrepare(staleReadyTile)
        let staleReadyMaterialized = await pipeline.waitUntilMaterialized(staleReadyTile)
        XCTAssertTrue(staleReadyMaterialized)
        pipeline.completeMaterialize(staleReadyTile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        loader.request(tiles: [staleLoadingTile])
        let staleLoadingStarted = await pipeline.waitUntilStarted(staleLoadingTile)
        XCTAssertTrue(staleLoadingStarted)
        loader.request(tiles: [currentTile])
        let currentStarted = await pipeline.waitUntilStarted(currentTile)
        XCTAssertTrue(currentStarted)

        let visibleTiles = reporter.snapshot().tiles.map(\.tile)
        XCTAssertFalse(visibleTiles.contains(staleReadyTile))
        XCTAssertTrue(visibleTiles.contains(staleLoadingTile))
        XCTAssertTrue(visibleTiles.contains(currentTile))

        pipeline.completeDownload(staleLoadingTile, result: .failure(.network))
        pipeline.completeDownload(currentTile, result: .failure(.network))
    }

    func testTileLoadingSnapshotIncludesDisplayedTilesOutsideCurrentDemand() {
        let reporter = TileLoadingStatusReporter()
        let displayedTile = Tile(x: 4, y: 2, z: 3)

        reporter.recordDemand(input: 0, deduplicated: 0, tiles: [])
        reporter.recordDisplayedTiles([displayedTile])

        let visibleTiles = reporter.snapshot().tiles.map(\.tile)
        XCTAssertEqual(visibleTiles, [displayedTile])
    }

    func testTileLoadingSnapshotDoesNotCapDisplayedTileRows() {
        let reporter = TileLoadingStatusReporter()
        let displayedTiles = (0..<80).map { Tile(x: $0, y: 1, z: 7) }

        reporter.recordDemand(input: 0, deduplicated: 0, tiles: [])
        reporter.recordDisplayedTiles(displayedTiles)

        XCTAssertEqual(reporter.snapshot().tiles.count, displayedTiles.count)
    }

    func testRequestKeepsInFlightTileWhenItTemporarilyLeavesDemand() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let firstTile = Tile(x: 1, y: 1, z: 4)
        let secondTile = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [firstTile])
        let firstTileStarted = await pipeline.waitUntilStarted(firstTile)
        XCTAssertTrue(firstTileStarted)

        loader.request(tiles: [secondTile])
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(pipeline.wasCanceled(firstTile))
        XCTAssertFalse(pipeline.hasStarted(secondTile))

        pipeline.completeDownload(firstTile, result: .failure(.network))
        let secondTileStarted = await pipeline.waitUntilStarted(secondTile)
        XCTAssertTrue(secondTileStarted)

        pipeline.completeDownload(secondTile, result: .failure(.network))
    }

    func testNetworkSlotFreesWhileParseIsStillRunning() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline(suspendsDiskReads: true)
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let firstTile = Tile(x: 1, y: 1, z: 4)
        let secondTile = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [firstTile, secondTile])
        // Deterministic ordering: the first tile takes the single network
        // slot, the second parks on it after its own disk miss.
        let firstRead = await pipeline.waitUntilDiskReadCount(1, for: firstTile)
        XCTAssertTrue(firstRead)
        pipeline.completeDiskRead(firstTile)
        let firstStarted = await pipeline.waitUntilStarted(firstTile)
        XCTAssertTrue(firstStarted)
        let secondRead = await pipeline.waitUntilDiskReadCount(1, for: secondTile)
        XCTAssertTrue(secondRead)
        pipeline.completeDiskRead(secondTile)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(pipeline.hasStarted(secondTile))

        pipeline.completeDownload(firstTile, result: .success(Data([1]), etag: nil))
        let firstPrepared = await pipeline.waitUntilPrepared(firstTile)
        XCTAssertTrue(firstPrepared)

        // The network slot freed up right after download: the second tile starts
        // downloading while the first is still parsing.
        let secondStarted = await pipeline.waitUntilStarted(secondTile)
        XCTAssertTrue(secondStarted)

        pipeline.completePrepare(firstTile)
        let firstMaterialized = await pipeline.waitUntilMaterialized(firstTile)
        XCTAssertTrue(firstMaterialized)
        pipeline.completeMaterialize(firstTile, result: true)
        pipeline.completeDownload(secondTile, result: .failure(.network))
    }

    func testCPUStageHonorsItsOwnConcurrencyLimit() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 2
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           maxConcurrentPrepares: 1)
        let firstTile = Tile(x: 1, y: 1, z: 4)
        let secondTile = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [firstTile, secondTile])
        let firstStarted = await pipeline.waitUntilStarted(firstTile)
        let secondStarted = await pipeline.waitUntilStarted(secondTile)
        XCTAssertTrue(firstStarted)
        XCTAssertTrue(secondStarted)

        pipeline.completeDownload(firstTile, result: .success(Data([1]), etag: nil))
        let firstPrepared = await pipeline.waitUntilPrepared(firstTile)
        XCTAssertTrue(firstPrepared)

        // The single CPU slot is occupied by the first tile: the second is downloaded, but its
        // parsing waits in the CPU-stage queue.
        pipeline.completeDownload(secondTile, result: .success(Data([2]), etag: nil))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(pipeline.hasPrepared(secondTile))

        pipeline.completePrepare(firstTile)
        let firstMaterialized = await pipeline.waitUntilMaterialized(firstTile)
        XCTAssertTrue(firstMaterialized)
        pipeline.completeMaterialize(firstTile, result: true)

        // The CPU slot freed up: the second tile's deferred CPU stage starts.
        let secondPrepared = await pipeline.waitUntilPrepared(secondTile)
        XCTAssertTrue(secondPrepared)
        pipeline.completePrepare(secondTile)
        let secondMaterialized = await pipeline.waitUntilMaterialized(secondTile)
        XCTAssertTrue(secondMaterialized)
        pipeline.completeMaterialize(secondTile, result: true)
    }

    func testQueuedCPUWorkIsPickedByDemandPriorityNotDownloadCompletionOrder() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 3
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           maxConcurrentPrepares: 1)
        let occupyingTile = Tile(x: 1, y: 1, z: 4)
        let nearTile = Tile(x: 2, y: 1, z: 4)
        let farTile = Tile(x: 3, y: 1, z: 4)

        // request() order = priority: occupying, then near, then far.
        loader.request(tiles: [occupyingTile, nearTile, farTile])
        for tile in [occupyingTile, nearTile, farTile] {
            let started = await pipeline.waitUntilStarted(tile)
            XCTAssertTrue(started)
        }

        // The first tile occupies the single CPU slot.
        pipeline.completeDownload(occupyingTile, result: .success(Data([1]), etag: nil))
        let occupyingPrepared = await pipeline.waitUntilPrepared(occupyingTile)
        XCTAssertTrue(occupyingPrepared)

        // The far tile downloaded BEFORE the near one: in FIFO it would parse first.
        pipeline.completeDownload(farTile, result: .success(Data([3]), etag: nil))
        try? await Task.sleep(nanoseconds: 50_000_000)
        pipeline.completeDownload(nearTile, result: .success(Data([2]), etag: nil))
        try? await Task.sleep(nanoseconds: 50_000_000)

        pipeline.completePrepare(occupyingTile)
        let occupyingMaterialized = await pipeline.waitUntilMaterialized(occupyingTile)
        XCTAssertTrue(occupyingMaterialized)
        pipeline.completeMaterialize(occupyingTile, result: true)

        // The slot freed up: the near tile parses (demand priority), not the far one.
        let nearPrepared = await pipeline.waitUntilPrepared(nearTile)
        XCTAssertTrue(nearPrepared)
        XCTAssertFalse(pipeline.hasPrepared(farTile))

        pipeline.completePrepare(nearTile)
        let nearMaterialized = await pipeline.waitUntilMaterialized(nearTile)
        XCTAssertTrue(nearMaterialized)
        pipeline.completeMaterialize(nearTile, result: true)

        let farPrepared = await pipeline.waitUntilPrepared(farTile)
        XCTAssertTrue(farPrepared)
        pipeline.completePrepare(farTile)
        let farMaterialized = await pipeline.waitUntilMaterialized(farTile)
        XCTAssertTrue(farMaterialized)
        pipeline.completeMaterialize(farTile, result: true)
    }

    func testFailedDownloadArmsRetryWakeThatFiresCallback() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let wakeScheduler = RecordingRetryWakeScheduler()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           retryWakeScheduler: wakeScheduler.schedule)
        let wakeExpectation = expectation(description: "retry wake callback fired")
        wakeExpectation.assertForOverFulfill = false
        loader.onFrameNeeded = { wakeExpectation.fulfill() }
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)

        pipeline.completeDownload(tile, result: .failure(.network))
        // The watchdog armed a wake at the disk deadline when the load
        // started; the failure replaces it with the retry window.
        let didSchedule = await wakeScheduler.waitUntilScheduledCount(2)
        XCTAssertTrue(didSchedule)
        guard let armedWake = wakeScheduler.liveWakes.first else {
            XCTFail("The failure armed no live wake")
            return
        }
        XCTAssertGreaterThan(armedWake.delay, 0)
        XCTAssertLessThanOrEqual(armedWake.delay, TileRetryController.Policy.default.baseBackoff)

        armedWake.workItem.perform()
        await fulfillment(of: [wakeExpectation], timeout: 2)
    }

    func testCancelAllCancelsArmedRetryWake() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let wakeScheduler = RecordingRetryWakeScheduler()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           retryWakeScheduler: wakeScheduler.schedule)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)

        pipeline.completeDownload(tile, result: .failure(.network))
        let didSchedule = await wakeScheduler.waitUntilScheduledCount(2)
        XCTAssertTrue(didSchedule)
        XCTAssertFalse(wakeScheduler.liveWakes.isEmpty)

        loader.cancelAll()

        XCTAssertTrue(wakeScheduler.liveWakes.isEmpty)
    }

    func testCancelAllClearsReporterStateAndIgnoresLatePreparationCompletion() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)
        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(didPrepare)
        XCTAssertEqual(reporter.snapshot().activeLoads, 1)
        XCTAssertEqual(reporter.snapshot().parsing.inFlight, 1)

        loader.cancelAll()

        var snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.requested, 0)
        XCTAssertEqual(snapshot.activeLoads, 0)
        XCTAssertEqual(snapshot.network.inFlight, 0)
        XCTAssertEqual(snapshot.parsing.inFlight, 0)
        XCTAssertNil(snapshot.latestNetworkTile)
        XCTAssertNil(snapshot.latestParsingTile)
        XCTAssertFalse(snapshot.tiles.contains { $0.tile == tile })

        pipeline.completePrepare(tile)
        try? await Task.sleep(nanoseconds: 50_000_000)

        snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.activeLoads, 0)
        XCTAssertEqual(snapshot.parsing.inFlight, 0)
        XCTAssertEqual(snapshot.totalCompleted, 0)
        XCTAssertEqual(snapshot.totalFailed, 0)
        XCTAssertFalse(pipeline.hasMaterialized(tile))
    }

    func testReporterCancellationClearsDemandWithoutActiveLoads() {
        let reporter = TileLoadingStatusReporter()
        let tile = Tile(x: 1, y: 1, z: 4)
        reporter.recordDemand(input: 1, deduplicated: 1, tiles: [tile])

        reporter.recordLoadsCancelled(tiles: [])

        let snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.requested, 0)
        XCTAssertEqual(snapshot.deduplicated, 0)
        XCTAssertTrue(snapshot.tiles.isEmpty)
    }

    func testCanceledSaveCompletionDoesNotFinishReplacementTaskForSameTile() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline(suspendsSaves: true, suspendsDiskReads: true)
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 1, y: 1, z: 4)
        let queuedTile = Tile(x: 2, y: 1, z: 4)
        let canceledFinishAttempted = expectation(description: "canceled load attempted deferred finish")
        canceledFinishAttempted.assertForOverFulfill = false
        loader.onFinishLoadingAttemptForTesting = { finishedTile in
            if finishedTile == tile {
                canceledFinishAttempted.fulfill()
            }
        }

        loader.request(tiles: [tile])
        let firstRead = await pipeline.waitUntilDiskReadCount(1, for: tile)
        XCTAssertTrue(firstRead)
        pipeline.completeDiskRead(tile)
        let firstStarted = await pipeline.waitUntilStartCount(1, for: tile)
        XCTAssertTrue(firstStarted)
        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3]), etag: nil))
        let firstPrepared = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(firstPrepared)
        pipeline.completePrepare(tile)
        let firstMaterialized = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(firstMaterialized)
        pipeline.completeMaterialize(tile, result: true)
        let firstSaveStarted = await pipeline.waitUntilSaveStarted(tile)
        XCTAssertTrue(firstSaveStarted)

        loader.cancelAll()
        XCTAssertEqual(reporter.snapshot().activeLoads, 0)
        loader.request(tiles: [tile, queuedTile])
        // Deterministic ordering: the replacement takes the single network
        // slot, the queued tile parks on it after its own disk miss.
        let replacementRead = await pipeline.waitUntilDiskReadCount(2, for: tile)
        XCTAssertTrue(replacementRead)
        pipeline.completeDiskRead(tile)
        let replacementStarted = await pipeline.waitUntilStartCount(2, for: tile)
        XCTAssertTrue(replacementStarted)
        let queuedRead = await pipeline.waitUntilDiskReadCount(1, for: queuedTile)
        XCTAssertTrue(queuedRead)
        pipeline.completeDiskRead(queuedTile)

        // The canceled first task resumes after a replacement for the same tile
        // has been installed. Its deferred finish must not remove that replacement.
        pipeline.completeSave(tile)
        await fulfillment(of: [canceledFinishAttempted], timeout: 2)
        XCTAssertFalse(pipeline.hasStarted(queuedTile))
        // Both replacement loads are in flight: one downloading, one past its
        // disk miss waiting for the single network slot.
        XCTAssertEqual(reporter.snapshot().activeLoads, 2)

        pipeline.completeDownload(tile, result: .failure(.network))
        let queuedStarted = await pipeline.waitUntilStarted(queuedTile)
        XCTAssertTrue(queuedStarted)
        pipeline.completeDownload(queuedTile, result: .failure(.network))
    }

    func testExpiredRetryWindowDoesNotMaskFutureWindowsOnRearm() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 2
        var now = Date(timeIntervalSince1970: 1000)
        let pipeline = ControlledTileLoadPipeline()
        let wakeScheduler = RecordingRetryWakeScheduler()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           now: { now },
                                           retryWakeScheduler: wakeScheduler.schedule)
        let firstTile = Tile(x: 1, y: 1, z: 4)
        let secondTile = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [firstTile, secondTile])
        let firstStarted = await pipeline.waitUntilStarted(firstTile)
        let secondStarted = await pipeline.waitUntilStarted(secondTile)
        XCTAssertTrue(firstStarted)
        XCTAssertTrue(secondStarted)

        // The first tile fails at T+0: its window is T+0.5, the alarm is armed
        // for it (replacing the watchdog's wake at the stage deadline).
        pipeline.completeDownload(firstTile, result: .failure(.network))
        let didScheduleFirst = await wakeScheduler.waitUntilScheduledCount(2)
        XCTAssertTrue(didScheduleFirst)
        let armedCount = wakeScheduler.scheduledWakes.count
        guard let retryWake = wakeScheduler.liveWakes.first else {
            XCTFail("The failure armed no live wake")
            return
        }
        XCTAssertEqual(retryWake.delay, 0.5, accuracy: 0.001)

        // The second fails at T+0.4: its T+0.9 window is absorbed by the earlier deadline.
        now = Date(timeIntervalSince1970: 1000.4)
        pipeline.completeDownload(secondTile, result: .failure(.network))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The alarm fires at T+0.6: the first tile's window has already expired and must not
        // mask the second's future window - re-arm for T+0.9.
        now = Date(timeIntervalSince1970: 1000.6)
        retryWake.workItem.perform()

        let didRearm = await wakeScheduler.waitUntilScheduledCount(armedCount + 1)
        XCTAssertTrue(didRearm)
        XCTAssertEqual(wakeScheduler.scheduledWakes.last?.delay ?? -1, 0.3, accuracy: 0.001)
    }

    // MARK: - Stage watchdog

    private static let shortDeadlines = ImmersiveMapNeedsTile.StageDeadlines(disk: 5, network: 5, cpu: 5)

    func testAStalledDiskStageIsRetiredAndTheTileRetriedAfterItsBackoff() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        var now = Date(timeIntervalSince1970: 1000)
        let pipeline = ControlledTileLoadPipeline(suspendsDiskReads: true)
        let reporter = TileLoadingStatusReporter()
        let wakeScheduler = RecordingRetryWakeScheduler()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           maxConcurrentDiskLoads: 1,
                                           stageDeadlines: Self.shortDeadlines,
                                           now: { now },
                                           retryWakeScheduler: wakeScheduler.schedule,
                                           tileLoadingStatusReporter: reporter)
        let stalled = Tile(x: 1, y: 1, z: 4)
        let waiting = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [stalled, waiting])
        let didStartRead = await pipeline.waitUntilDiskReadStarted(stalled)
        XCTAssertTrue(didStartRead)
        XCTAssertEqual(reporter.snapshot().disk.inFlight, 1)
        XCTAssertFalse(pipeline.hasDiskReadStarted(waiting), "The one disk slot is held by the read that never answers")

        // Inside the deadline a frame's request leaves the load alone.
        now = Date(timeIntervalSince1970: 1004)
        loader.request(tiles: [stalled, waiting])
        XCTAssertEqual(reporter.snapshot().tiles.first { $0.tile == stalled }?.detail, "disk")

        // Past it, the load is retired: the row says so, the slot is free
        // and goes to the tile that waited for it.
        now = Date(timeIntervalSince1970: 1006)
        loader.request(tiles: [stalled, waiting])

        let retired = reporter.snapshot()
        let row = retired.tiles.first { $0.tile == stalled }
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.detail, "stalled in disk")
        XCTAssertEqual(retired.disk.inFlight, 0)
        XCTAssertEqual(retired.totalFailed, 1)
        let waitingStarted = await pipeline.waitUntilDiskReadStarted(waiting)
        XCTAssertTrue(waitingStarted)
        // Its miss hands the slot back, so the retired tile can use it.
        pipeline.completeDiskRead(waiting)
        let waitingDownloading = await pipeline.waitUntilStarted(waiting)
        XCTAssertTrue(waitingDownloading)

        // The stalled tile sits out its backoff, then runs the whole chain again.
        loader.request(tiles: [stalled])
        XCTAssertEqual(pipeline.diskReadCount(for: stalled), 1)
        now = Date(timeIntervalSince1970: 1007)
        loader.request(tiles: [stalled])
        let didReadAgain = await pipeline.waitUntilDiskReadCount(2, for: stalled)
        XCTAssertTrue(didReadAgain)

        // The retired task's late answer changes nothing: its generation is gone.
        pipeline.completeDiskRead(stalled)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(reporter.snapshot().tiles.first { $0.tile == stalled }?.detail, "disk")

        loader.cancelAll()
        pipeline.completeDiskRead(stalled)
        pipeline.completeDiskRead(waiting)
    }

    func testAStalledParseIsRetiredAndFreesItsCPUSlot() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 2
        var now = Date(timeIntervalSince1970: 1000)
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let wakeScheduler = RecordingRetryWakeScheduler()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           maxConcurrentPrepares: 1,
                                           stageDeadlines: Self.shortDeadlines,
                                           now: { now },
                                           retryWakeScheduler: wakeScheduler.schedule,
                                           tileLoadingStatusReporter: reporter)
        let stalled = Tile(x: 1, y: 1, z: 4)
        let waiting = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [stalled, waiting])
        let stalledStarted = await pipeline.waitUntilStarted(stalled)
        let waitingStarted = await pipeline.waitUntilStarted(waiting)
        XCTAssertTrue(stalledStarted)
        XCTAssertTrue(waitingStarted)

        pipeline.completeDownload(stalled, result: .success(Data([1]), etag: nil))
        let stalledParsing = await pipeline.waitUntilPrepared(stalled)
        XCTAssertTrue(stalledParsing)
        pipeline.completeDownload(waiting, result: .success(Data([2]), etag: nil))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(pipeline.hasPrepared(waiting), "The one CPU slot is held by the parse that never ends")
        XCTAssertEqual(reporter.snapshot().tiles.first { $0.tile == stalled }?.detail, "parse")

        now = Date(timeIntervalSince1970: 1006)
        loader.request(tiles: [stalled, waiting])

        let row = reporter.snapshot().tiles.first { $0.tile == stalled }
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.detail, "stalled in parse")
        let waitingParsing = await pipeline.waitUntilPrepared(waiting)
        XCTAssertTrue(waitingParsing, "The freed CPU slot goes to the queued parse")
        XCTAssertEqual(reporter.snapshot().parsing.inFlight, 1)

        // The retired parse answering late is ignored, the waiting one lands.
        pipeline.completePrepare(stalled)
        pipeline.completePrepare(waiting)
        let didMaterialize = await pipeline.waitUntilMaterialized(waiting)
        XCTAssertTrue(didMaterialize)
        pipeline.completeMaterialize(waiting, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let final = reporter.snapshot()
        XCTAssertEqual(final.parsing.inFlight, 0)
        XCTAssertEqual(final.tiles.first { $0.tile == stalled }?.detail, "stalled in parse")
        XCTAssertEqual(final.tiles.first { $0.tile == waiting }?.status, .ready)
        loader.cancelAll()
    }

    func testTheWatchdogWakeRetiresAStalledLoadWithoutAFrame() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        var now = Date(timeIntervalSince1970: 1000)
        let pipeline = ControlledTileLoadPipeline(suspendsDiskReads: true)
        let reporter = TileLoadingStatusReporter()
        let wakeScheduler = RecordingRetryWakeScheduler()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           stageDeadlines: Self.shortDeadlines,
                                           now: { now },
                                           retryWakeScheduler: wakeScheduler.schedule,
                                           tileLoadingStatusReporter: reporter)
        let wakeExpectation = expectation(description: "the wake asked for a frame")
        wakeExpectation.assertForOverFulfill = false
        loader.onFrameNeeded = { wakeExpectation.fulfill() }
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let didStartRead = await pipeline.waitUntilDiskReadStarted(tile)
        XCTAssertTrue(didStartRead)

        // The stage start armed the wake at its deadline: a still scene
        // renders no frame, so this is what notices the stall.
        guard let watchdogWake = wakeScheduler.liveWakes.first else {
            XCTFail("The stage start armed no wake")
            return
        }
        XCTAssertEqual(watchdogWake.delay, Self.shortDeadlines.disk, accuracy: 0.001)

        now = Date(timeIntervalSince1970: 1005.5)
        watchdogWake.workItem.perform()

        await fulfillment(of: [wakeExpectation], timeout: 2)
        let snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.tiles.first { $0.tile == tile }?.detail, "stalled in disk")
        XCTAssertEqual(snapshot.disk.inFlight, 0)
        // Re-armed for the retry window, so the frame that re-requests the
        // tile comes on its own too.
        XCTAssertEqual(wakeScheduler.liveWakes.last?.delay ?? -1,
                       TileRetryController.Policy.default.baseBackoff,
                       accuracy: 0.001)

        loader.cancelAll()
        pipeline.completeDiskRead(tile)
    }

    func testALandedLoadPastItsDeadlineIsRetiredWithoutAFailure() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 2
        var now = Date(timeIntervalSince1970: 1000)
        let pipeline = ControlledTileLoadPipeline(suspendsSaves: true)
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           maxConcurrentPrepares: 1,
                                           stageDeadlines: Self.shortDeadlines,
                                           now: { now },
                                           retryWakeScheduler: RecordingRetryWakeScheduler().schedule,
                                           tileLoadingStatusReporter: reporter)
        let landed = Tile(x: 1, y: 1, z: 4)
        let waiting = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [landed, waiting])
        _ = await pipeline.waitUntilStarted(landed)
        _ = await pipeline.waitUntilStarted(waiting)
        pipeline.completeDownload(landed, result: .success(Data([1]), etag: nil))
        _ = await pipeline.waitUntilPrepared(landed)
        pipeline.completePrepare(landed)
        _ = await pipeline.waitUntilMaterialized(landed)
        pipeline.completeMaterialize(landed, result: true)
        let saveStarted = await pipeline.waitUntilSaveStarted(landed)
        XCTAssertTrue(saveStarted)
        XCTAssertEqual(reporter.snapshot().tiles.first { $0.tile == landed }?.detail, "ready")
        pipeline.completeDownload(waiting, result: .success(Data([2]), etag: nil))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(pipeline.hasPrepared(waiting), "The save still holds the one CPU slot")

        // The save outlives the deadline: the slot is owed, nothing failed.
        // The frame draws the landed tile and asks only for what is missing.
        reporter.recordDisplayedTiles([landed])
        now = Date(timeIntervalSince1970: 1006)
        loader.request(tiles: [waiting])

        let snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.tiles.first { $0.tile == landed }?.status, .ready)
        XCTAssertEqual(snapshot.tiles.first { $0.tile == landed }?.detail, "displayed")
        XCTAssertEqual(snapshot.totalFailed, 0)
        XCTAssertNil(snapshot.latestFailure)
        let waitingParsing = await pipeline.waitUntilPrepared(waiting)
        XCTAssertTrue(waitingParsing, "The freed slot goes to the queued parse")

        loader.cancelAll()
        pipeline.completeSave(landed)
        pipeline.completePrepare(waiting)
    }

    func testADemandThatReturnsWhileTheSaveRunsIsServedByTheNextFrame() async {
        let settings = ImmersiveMapSettings.default
        let pipeline = ControlledTileLoadPipeline(suspendsSaves: true)
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 77, y: 40, z: 7)
        let frameRequested = expectation(description: "the loader asked for a frame")
        frameRequested.assertForOverFulfill = false
        // What the store does with the hook: a frame, whose request runs
        // the demand again.
        loader.onFrameNeeded = { [weak loader] in
            frameRequested.fulfill()
            loader?.request(tiles: [tile])
        }

        // Frame 1: the tile is demanded, loads, and lands.
        loader.request(tiles: [tile])
        _ = await pipeline.waitUntilStarted(tile)
        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3]), etag: nil))
        _ = await pipeline.waitUntilPrepared(tile)
        pipeline.completePrepare(tile)
        _ = await pipeline.waitUntilMaterialized(tile)
        pipeline.completeMaterialize(tile, result: true)
        let saveStarted = await pipeline.waitUntilSaveStarted(tile)
        XCTAssertTrue(saveStarted)

        // Frame 2, the one the landing invalidated: the camera moved on,
        // the working set released the tile. Frame 3: the camera is back,
        // the tile is not resident, and the load still stands.
        loader.request(tiles: [])
        loader.request(tiles: [tile])
        XCTAssertEqual(pipeline.diskReadCount(for: tile), 1, "The standing load answers the returned demand")

        // The save ends: the load asks for a frame, whose demand starts a
        // fresh load instead of leaving the hole until the next gesture.
        pipeline.completeSave(tile)
        await fulfillment(of: [frameRequested], timeout: 5)
        let secondLoad = await pipeline.waitUntilDiskReadCount(2, for: tile)
        XCTAssertTrue(secondLoad)
        loader.cancelAll()
    }

    func testAMaterializeFailureBacksOffLikeATransientError() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let wakeScheduler = RecordingRetryWakeScheduler()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           retryWakeScheduler: wakeScheduler.schedule,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        _ = await pipeline.waitUntilStarted(tile)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: nil))
        _ = await pipeline.waitUntilPrepared(tile)
        pipeline.completePrepare(tile)
        _ = await pipeline.waitUntilMaterialized(tile)
        pipeline.completeMaterialize(tile, result: false)
        let failed = await reporter.waitUntilStatus(.failed, for: tile)
        XCTAssertEqual(failed?.detail, "materialize_failed")

        guard let retryWake = wakeScheduler.liveWakes.first else {
            XCTFail("The failure armed no live wake")
            return
        }
        XCTAssertLessThanOrEqual(retryWake.delay, TileRetryController.Policy.default.baseBackoff,
                                 "Memory pressure passes; the parse cooldown would park the tile for minutes")
        loader.cancelAll()
    }

    // MARK: - Disk stage

    func testDiskHitEndsTheLoadWithoutDownload() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let served = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(served)
        pipeline.completeMaterialize(tile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The hit is final: no download, no parse, no save, one materialize.
        XCTAssertFalse(pipeline.hasStarted(tile))
        XCTAssertFalse(pipeline.hasPrepared(tile))
        XCTAssertEqual(pipeline.materializeCount(for: tile), 1)
        XCTAssertNil(pipeline.savedETag(for: tile))
        let snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.disk.completed, 1)
        XCTAssertEqual(snapshot.totalCompleted, 1)
        XCTAssertEqual(snapshot.activeLoads, 0)
    }

    func testDiskMissProceedsToDownload() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)

        XCTAssertEqual(pipeline.diskReadCount(for: tile), 1)
        XCTAssertEqual(reporter.snapshot().disk.failed, 1)

        pipeline.completeDownload(tile, result: .failure(.network))
    }

    func testDiskLaneRunsWhileAllNetworkSlotsAreBusy() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let coldTile = Tile(x: 1, y: 1, z: 4)
        let warmTile = Tile(x: 2, y: 1, z: 4)
        pipeline.setDiskEntry(warmTile, etag: "A")

        loader.request(tiles: [coldTile, warmTile])
        let downloadStarted = await pipeline.waitUntilStarted(coldTile)
        XCTAssertTrue(downloadStarted)

        // The single network slot is held by the cold tile; the warm one is
        // served from disk anyway.
        let served = await pipeline.waitUntilMaterialized(warmTile)
        XCTAssertTrue(served)
        pipeline.completeMaterialize(warmTile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(pipeline.hasStarted(warmTile))

        pipeline.completeDownload(coldTile, result: .failure(.network))
    }

    func testDiskHitDoesNotReleaseTheBusyNetworkSlot() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline(suspendsDiskReads: true)
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           maxConcurrentDiskLoads: 3)
        let downloadingTile = Tile(x: 1, y: 1, z: 4)
        let warmTile = Tile(x: 2, y: 1, z: 4)
        let parkedTile = Tile(x: 3, y: 1, z: 4)
        pipeline.setDiskEntry(warmTile, etag: "A")

        loader.request(tiles: [downloadingTile, warmTile, parkedTile])
        // Deterministic ordering: the cold tile takes the network slot first.
        let firstRead = await pipeline.waitUntilDiskReadStarted(downloadingTile)
        XCTAssertTrue(firstRead)
        pipeline.completeDiskRead(downloadingTile)
        let downloadStarted = await pipeline.waitUntilStarted(downloadingTile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDiskRead(parkedTile)
        pipeline.completeDiskRead(warmTile)

        let served = await pipeline.waitUntilMaterialized(warmTile)
        XCTAssertTrue(served)
        pipeline.completeMaterialize(warmTile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // A wrongly released network slot would start the parked download
        // while the first is still in flight.
        XCTAssertFalse(pipeline.hasStarted(parkedTile))

        pipeline.completeDownload(downloadingTile, result: .failure(.network))
        let parkedStarted = await pipeline.waitUntilStarted(parkedTile)
        XCTAssertTrue(parkedStarted)
        pipeline.completeDownload(parkedTile, result: .failure(.network))
    }

    func testDiskStageHonorsItsOwnConcurrencyLimit() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 2
        let pipeline = ControlledTileLoadPipeline(suspendsDiskReads: true)
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           maxConcurrentDiskLoads: 1)
        let firstTile = Tile(x: 1, y: 1, z: 4)
        let secondTile = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [firstTile, secondTile])
        let firstReadStarted = await pipeline.waitUntilDiskReadStarted(firstTile)
        XCTAssertTrue(firstReadStarted)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(pipeline.hasDiskReadStarted(secondTile))

        // The freed disk slot admits the second read.
        pipeline.completeDiskRead(firstTile)
        let secondReadStarted = await pipeline.waitUntilDiskReadStarted(secondTile)
        XCTAssertTrue(secondReadStarted)
        pipeline.completeDiskRead(secondTile)

        for tile in [firstTile, secondTile] {
            let downloadStarted = await pipeline.waitUntilStarted(tile)
            XCTAssertTrue(downloadStarted)
            pipeline.completeDownload(tile, result: .failure(.network))
        }
    }

    func testCancelAllDuringDiskStageLeaksNoDiskSlot() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline(suspendsDiskReads: true)
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           maxConcurrentDiskLoads: 1)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let readStarted = await pipeline.waitUntilDiskReadStarted(tile)
        XCTAssertTrue(readStarted)

        loader.cancelAll()
        // The cancelled read resumes into a no-op behind the generation gate.
        pipeline.completeDiskRead(tile)

        // A leaked disk slot would keep the replacement's read from starting.
        loader.request(tiles: [tile])
        let replacementRead = await pipeline.waitUntilDiskReadCount(2, for: tile)
        XCTAssertTrue(replacementRead)
        pipeline.completeDiskRead(tile)
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .failure(.network))
    }

    func testStageNamesForADiskHitAreDiskAndReady() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let served = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(served)
        pipeline.completeMaterialize(tile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let stages = reporter.snapshot().tiles.first?.preparationStages
        XCTAssertEqual(stages?.map(\.name), ["disk", "ready"])
    }

    func testIsPreparedOnDiskFollowsThePipelineAndTheDiskStage() {
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: ImmersiveMapSettings.default, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        XCTAssertFalse(loader.isPreparedOnDisk(tile))
        pipeline.setDiskEntry(tile, etag: nil)
        XCTAssertTrue(loader.isPreparedOnDisk(tile))

        let cacheless = ControlledTileLoadPipeline(hasPreparedDiskCache: false)
        cacheless.setDiskEntry(tile, etag: nil)
        let cachelessLoader = ImmersiveMapNeedsTile(config: ImmersiveMapSettings.default, loadPipeline: cacheless)
        XCTAssertFalse(cachelessLoader.isPreparedOnDisk(tile), "Without a disk stage nothing is on disk")
    }

    func testCachelessPipelineSkipsTheDiskStage() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline(hasPreparedDiskCache: false)
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let tile = Tile(x: 1, y: 1, z: 4)
        // Even a present entry must not be consulted without a cache.
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(didPrepare)
        pipeline.completePrepare(tile)
        let didMaterialize = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(didMaterialize)
        pipeline.completeMaterialize(tile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(pipeline.diskReadCount(for: tile), 0)
        let snapshot = reporter.snapshot()
        XCTAssertEqual(snapshot.disk, TileLoadingPhaseSnapshot(inFlight: 0, completed: 0, failed: 0))
        XCTAssertEqual(snapshot.tiles.first?.preparationStages.map(\.name),
                       ["network", "parse", "materialize", "ready"])
    }

    func testUnwantedTileWaitingForANetworkSlotIsDroppedOnTheNextRequest() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline(suspendsDiskReads: true)
        let reporter = TileLoadingStatusReporter()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let downloadingTile = Tile(x: 1, y: 1, z: 4)
        let parkedTile = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [downloadingTile, parkedTile])
        // Deterministic ordering: the first tile takes the network slot, the
        // second parks on it.
        let firstRead = await pipeline.waitUntilDiskReadStarted(downloadingTile)
        XCTAssertTrue(firstRead)
        pipeline.completeDiskRead(downloadingTile)
        let downloadStarted = await pipeline.waitUntilStarted(downloadingTile)
        XCTAssertTrue(downloadStarted)
        let secondRead = await pipeline.waitUntilDiskReadStarted(parkedTile)
        XCTAssertTrue(secondRead)
        pipeline.completeDiskRead(parkedTile)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Demand moves on while the parked tile waits for the network slot:
        // it must not download bytes nobody wants any more.
        loader.request(tiles: [downloadingTile])
        pipeline.completeDownload(downloadingTile, result: .success(Data([1]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(downloadingTile)
        XCTAssertTrue(didPrepare)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(pipeline.hasStarted(parkedTile))
        XCTAssertEqual(reporter.snapshot().activeLoads, 1)

        // Wanted again later: the whole chain runs afresh, disk stage first.
        loader.request(tiles: [downloadingTile, parkedTile])
        let replacementRead = await pipeline.waitUntilDiskReadCount(2, for: parkedTile)
        XCTAssertTrue(replacementRead)
        pipeline.completeDiskRead(parkedTile)
        let parkedDownloadStarted = await pipeline.waitUntilStarted(parkedTile)
        XCTAssertTrue(parkedDownloadStarted)
        pipeline.completeDownload(parkedTile, result: .failure(.network))
        pipeline.completePrepare(downloadingTile)
        let materialized = await pipeline.waitUntilMaterialized(downloadingTile)
        XCTAssertTrue(materialized)
        pipeline.completeMaterialize(downloadingTile, result: true)
    }

    func testRetryBlockedTileDoesNotReadDisk() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .failure(.network))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Within the backoff window a re-request must not even probe the
        // disk: a hit would have ended the load before the failure.
        loader.request(tiles: [tile])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(pipeline.diskReadCount(for: tile), 1)
    }

    func testCPUStageReusesAnEntrySavedBetweenDiskMissAndDownload() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)

        // A second engine sharing the namespace saves the entry meanwhile;
        // the matching ETag proves it was parsed from these exact bytes.
        pipeline.setDiskEntry(tile, etag: "A")
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: "A"))
        let reused = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(reused)
        pipeline.completeMaterialize(tile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(pipeline.hasPrepared(tile))
        XCTAssertEqual(pipeline.materializeCount(for: tile), 1)
        XCTAssertNil(pipeline.savedETag(for: tile))
    }

    func testParseFailureKeepsTheDiskPair() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(didPrepare)
        pipeline.completePrepareFailing(tile)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The disk stage already judged whatever pair exists; a parse failure
        // of fresh bytes says nothing about it, and deleting here could snipe
        // an entry a second engine saved moments ago.
        XCTAssertFalse(pipeline.hasRemovedFromDisk(tile))
    }

    func testUnreadableDiskImageRemovesThePairAndContinuesToNetwork() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let serveStarted = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(serveStarted)
        // The disk stage read a corrupt entry (bad blob, checksum mismatch,
        // torn pair): the pair must be deleted so the tile re-parses instead
        // of failing the same way on every retry.
        pipeline.completeMaterialize(tile, outcome: .imageUnreadable)

        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        XCTAssertTrue(pipeline.hasRemovedFromDisk(tile))
        pipeline.completeDownload(tile, result: .failure(.network))
    }

    /// Regression: transient memory pressure while materializing an entry
    /// used to delete the healthy pair. The entry must survive both the disk
    /// stage's failure and the CPU stage's ETag-matched retry, and the load
    /// must fall through to parsing the downloaded bytes.
    func testAllocationFailureOnDiskHitKeepsThePairAndFallsThroughToParse() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let serveStarted = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(serveStarted)
        // The disk stage fails transiently: the pair stays, the network runs.
        pipeline.completeMaterialize(tile, outcome: .allocationOrStoreFailed)

        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: "A"))
        // The CPU stage retries the ETag-matched entry and hits memory
        // pressure again.
        let retried = await pipeline.waitUntilMaterializeCount(2, for: tile)
        XCTAssertTrue(retried)
        pipeline.completeMaterialize(tile, outcome: .allocationOrStoreFailed)

        // The healthy pair stays on disk; the fresh bytes parse instead.
        let reparsed = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(reparsed)
        XCTAssertFalse(pipeline.hasRemovedFromDisk(tile))

        pipeline.completePrepare(tile)
        let swapped = await pipeline.waitUntilMaterializeCount(3, for: tile)
        XCTAssertTrue(swapped)
        pipeline.completeMaterialize(tile, result: true)
        let saved = await pipeline.waitUntilSaved(tile)
        XCTAssertTrue(saved)

        XCTAssertFalse(pipeline.hasRemovedFromDisk(tile))
        XCTAssertEqual(pipeline.savedETag(for: tile), .some("A"))
    }

    func testUnreadableETagMatchedEntryRemovesThePairAndReparses() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let serveStarted = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(serveStarted)
        pipeline.completeMaterialize(tile, outcome: .allocationOrStoreFailed)

        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: "A"))
        let retried = await pipeline.waitUntilMaterializeCount(2, for: tile)
        XCTAssertTrue(retried)
        // This time the entry is genuinely corrupt: it must be removed and
        // the downloaded bytes parsed.
        pipeline.completeMaterialize(tile, outcome: .imageUnreadable)

        let reparsed = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(reparsed)
        XCTAssertTrue(pipeline.hasRemovedFromDisk(tile))

        pipeline.completePrepare(tile)
        let swapped = await pipeline.waitUntilMaterializeCount(3, for: tile)
        XCTAssertTrue(swapped)
        pipeline.completeMaterialize(tile, result: true)
        let saved = await pipeline.waitUntilSaved(tile)
        XCTAssertTrue(saved)

        XCTAssertEqual(pipeline.savedETag(for: tile), .some("A"))
    }

    /// A superseded load that read a corrupt entry must not delete the fresh
    /// pair its replacement may have just saved: cancellation wins over the
    /// unreadable outcome.
    func testCancelledLoadDoesNotRemoveThePairForUnreadableImage() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let serveStarted = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(serveStarted)

        loader.cancelAll()
        pipeline.completeMaterialize(tile, outcome: .imageUnreadable)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(pipeline.hasRemovedFromDisk(tile))
    }
}

private extension TileLoadingStatusReporter {
    func waitUntilStatus(_ status: TileLoadingTileStatus, for tile: Tile) async -> TileLoadingStatusTileSnapshot? {
        for _ in 0..<500 {
            if let row = snapshot().tiles.first(where: { $0.tile == tile }), row.status == status {
                return row
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return snapshot().tiles.first { $0.tile == tile }
    }
}
