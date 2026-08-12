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
        XCTAssertEqual(stages?.map(\.name), ["network", "parse", "materialize", "ready"])
        XCTAssertEqual(stages?[0].duration ?? 0, 0.100, accuracy: 0.001)
        XCTAssertEqual(stages?[1].duration ?? 0, 0.250, accuracy: 0.001)
        XCTAssertEqual(stages?[2].duration ?? 0, 0.030, accuracy: 0.001)
        XCTAssertEqual(stages?[1].layerTimings.map(\.layerName), ["land", "water_polygons", "streets"])
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
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let firstTile = Tile(x: 1, y: 1, z: 4)
        let secondTile = Tile(x: 2, y: 1, z: 4)

        loader.request(tiles: [firstTile, secondTile])
        let firstStarted = await pipeline.waitUntilStarted(firstTile)
        XCTAssertTrue(firstStarted)
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
        loader.onRetryWindowExpired = { wakeExpectation.fulfill() }
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)

        pipeline.completeDownload(tile, result: .failure(.network))
        let didSchedule = await wakeScheduler.waitUntilScheduledCount(1)
        XCTAssertTrue(didSchedule)
        guard let armedWake = wakeScheduler.scheduledWakes.first else {
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
        let didSchedule = await wakeScheduler.waitUntilScheduledCount(1)
        XCTAssertTrue(didSchedule)

        loader.cancelAll()

        XCTAssertTrue(wakeScheduler.scheduledWakes[0].workItem.isCancelled)
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
        let pipeline = ControlledTileLoadPipeline(suspendsSaves: true)
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
        let replacementStarted = await pipeline.waitUntilStartCount(2, for: tile)
        XCTAssertTrue(replacementStarted)

        // The canceled first task resumes after a replacement for the same tile
        // has been installed. Its deferred finish must not remove that replacement.
        pipeline.completeSave(tile)
        await fulfillment(of: [canceledFinishAttempted], timeout: 2)
        XCTAssertFalse(pipeline.hasStarted(queuedTile))
        XCTAssertEqual(reporter.snapshot().activeLoads, 1)

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

        // The first tile fails at T+0: its window is T+0.5, the alarm is armed for it.
        pipeline.completeDownload(firstTile, result: .failure(.network))
        let didScheduleFirst = await wakeScheduler.waitUntilScheduledCount(1)
        XCTAssertTrue(didScheduleFirst)

        // The second fails at T+0.4: its T+0.9 window is absorbed by the earlier deadline.
        now = Date(timeIntervalSince1970: 1000.4)
        pipeline.completeDownload(secondTile, result: .failure(.network))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The alarm fires at T+0.6: the first tile's window has already expired and must not
        // mask the second's future window - re-arm for T+0.9.
        now = Date(timeIntervalSince1970: 1000.6)
        wakeScheduler.scheduledWakes[0].workItem.perform()

        let didRearm = await wakeScheduler.waitUntilScheduledCount(2)
        XCTAssertTrue(didRearm)
        XCTAssertEqual(wakeScheduler.scheduledWakes[1].delay, 0.3, accuracy: 0.001)
    }

    // MARK: - Disk-first serve and revalidation

    func testNetworkSlotFreesWhileDiskFirstServeIsStillRunning() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline(suspendsDiskReads: true)
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let servedTile = Tile(x: 1, y: 1, z: 4)
        let coldTile = Tile(x: 2, y: 1, z: 4)
        pipeline.setDiskEntry(servedTile, etag: "A")

        loader.request(tiles: [servedTile, coldTile])
        let downloadStarted = await pipeline.waitUntilStarted(servedTile)
        XCTAssertTrue(downloadStarted)
        let diskReadStarted = await pipeline.waitUntilDiskReadStarted(servedTile)
        XCTAssertTrue(diskReadStarted)

        // The download finishes while the disk serve is still suspended: the
        // network slot must recycle immediately, without waiting for the serve.
        pipeline.completeDownload(servedTile, result: .success(Data([1]), etag: "A"))
        let coldStarted = await pipeline.waitUntilStarted(coldTile)
        XCTAssertTrue(coldStarted)

        pipeline.completeDiskRead(servedTile)
        let served = await pipeline.waitUntilMaterialized(servedTile)
        XCTAssertTrue(served)
        pipeline.completeMaterialize(servedTile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(pipeline.hasRevalidated(servedTile))

        pipeline.completeDownload(coldTile, result: .failure(.network))
    }

    func testWarmDiskServesTileWhileDownloadIsStillInFlight() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)

        // The tile materializes from disk before the download is completed.
        let materializedEarly = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(materializedEarly)
        XCTAssertEqual(pipeline.materializeFlagHistory(for: tile), [true])
        pipeline.completeMaterialize(tile, result: true)

        pipeline.completeDownload(tile, result: .success(Data([1]), etag: "A"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // A matching ETag confirms the served content: no parse, no second
        // materialize, the disk entry stays, and the serve is resolved so the
        // render store stops re-requesting the tile.
        XCTAssertFalse(pipeline.hasPrepared(tile))
        XCTAssertEqual(pipeline.materializeCount(for: tile), 1)
        XCTAssertFalse(pipeline.hasRemovedFromDisk(tile))
        XCTAssertTrue(pipeline.hasRevalidated(tile))
    }

    func testRevalidationMismatchReparsesFreshBytesAndSwapsTile() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        let servedFromDisk = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(servedFromDisk)
        pipeline.completeMaterialize(tile, result: true)

        // The server has newer content under a different ETag.
        pipeline.completeDownload(tile, result: .success(Data([2]), etag: "B"))
        let reparsed = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(reparsed)
        pipeline.completePrepare(tile)
        let swapped = await pipeline.waitUntilMaterializeCount(2, for: tile)
        XCTAssertTrue(swapped)
        pipeline.completeMaterialize(tile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(pipeline.savedETag(for: tile), .some("B"))
        // The serve was flagged as awaiting revalidation; the swap cleared it.
        XCTAssertEqual(pipeline.materializeFlagHistory(for: tile), [true, false])
        XCTAssertFalse(pipeline.hasRevalidated(tile))
    }

    func testNetworkFailureAfterDiskFirstServeIsASuccessNotAFailure() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let wakeScheduler = RecordingRetryWakeScheduler()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           retryWakeScheduler: wakeScheduler.schedule)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        let servedFromDisk = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(servedFromDisk)
        pipeline.completeMaterialize(tile, result: true)

        pipeline.completeDownload(tile, result: .failure(.network))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The served content stands: no retry backoff is armed, nothing parsed,
        // and the serve is resolved (accepted as offline content).
        XCTAssertTrue(wakeScheduler.scheduledWakes.isEmpty)
        XCTAssertFalse(pipeline.hasPrepared(tile))
        XCTAssertEqual(pipeline.materializeCount(for: tile), 1)
        XCTAssertTrue(pipeline.hasRevalidated(tile))
    }

    func testParseFailureAfterDiskFirstServeKeepsTheDiskEntry() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        let servedFromDisk = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(servedFromDisk)
        pipeline.completeMaterialize(tile, result: true)

        pipeline.completeDownload(tile, result: .success(Data([2]), etag: "B"))
        let reparsed = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(reparsed)
        pipeline.completePrepareFailing(tile)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Fresh bytes failed to parse, but the entry on screen is the best
        // content we have: it must not be deleted, and the serve must stay
        // unresolved so the render store keeps the tile requestable.
        XCTAssertFalse(pipeline.hasRemovedFromDisk(tile))
        XCTAssertFalse(pipeline.hasRevalidated(tile))
        XCTAssertEqual(pipeline.materializeFlagHistory(for: tile), [true])
    }

    func testParseFailureWithoutDiskFirstServeStillRemovesTheDiskEntry() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)

        loader.request(tiles: [tile])
        let didStart = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(didStart)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: nil))
        let didPrepare = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(didPrepare)
        pipeline.completePrepareFailing(tile)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(pipeline.hasRemovedFromDisk(tile))
    }

    func testServedEntryWithoutETagIsReplacedByFreshParse() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        // An entry saved from a response without an ETag cannot be revalidated.
        pipeline.setDiskEntry(tile, etag: nil)

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        let servedFromDisk = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(servedFromDisk)
        pipeline.completeMaterialize(tile, result: true)

        pipeline.completeDownload(tile, result: .success(Data([2]), etag: "C"))
        let reparsed = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(reparsed)
        pipeline.completePrepare(tile)
        let swapped = await pipeline.waitUntilMaterializeCount(2, for: tile)
        XCTAssertTrue(swapped)
        pipeline.completeMaterialize(tile, result: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(pipeline.savedETag(for: tile), .some("C"))
    }

    func testUnreadableDiskImageOnServeRemovesThePair() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let serveStarted = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(serveStarted)
        // The disk-first serve reads a corrupt entry (bad blob, checksum
        // mismatch, torn pair): the pair must be deleted so the tile
        // re-parses instead of failing the same way on every retry.
        pipeline.completeMaterialize(tile, outcome: .imageUnreadable)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(pipeline.hasRemovedFromDisk(tile))

        pipeline.completeDownload(tile, result: .failure(.network))
    }

    /// Regression: transient memory pressure while materializing an
    /// ETag-matched entry used to delete the healthy pair (and did so outside
    /// the generation gate). The entry must survive and the load must fall
    /// through to parsing the downloaded bytes.
    func testAllocationFailureOnETagMatchedEntryKeepsTheDiskPair() async {
        var settings = ImmersiveMapSettings.default
        settings.tiles.network.maxConcurrentFetches = 1
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings, loadPipeline: pipeline)
        let tile = Tile(x: 1, y: 1, z: 4)
        pipeline.setDiskEntry(tile, etag: "A")

        loader.request(tiles: [tile])
        let serveStarted = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(serveStarted)
        // The disk-first serve fails transiently, so the download result is
        // not a confirmation and the CPU stage runs.
        pipeline.completeMaterialize(tile, outcome: .allocationOrStoreFailed)

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
        try? await Task.sleep(nanoseconds: 100_000_000)

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
        try? await Task.sleep(nanoseconds: 100_000_000)

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

private final class RecordingRetryWakeScheduler {
    struct ScheduledWake {
        let delay: TimeInterval
        let workItem: DispatchWorkItem
    }

    private let lock = NSLock()
    private var wakes: [ScheduledWake] = []

    var scheduledWakes: [ScheduledWake] {
        lock.lock()
        defer { lock.unlock() }
        return wakes
    }

    func schedule(delay: TimeInterval, workItem: DispatchWorkItem) {
        lock.lock()
        wakes.append(ScheduledWake(delay: delay, workItem: workItem))
        lock.unlock()
    }

    func waitUntilScheduledCount(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if scheduledWakes.count >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

private final class ControlledTileLoadPipeline: TileLoadPipeline, @unchecked Sendable {
    private let suspendsSaves: Bool
    private let suspendsDiskReads: Bool
    private let lock = NSLock()
    private var diskReadStartedTiles: Set<Tile> = []
    private var diskReadContinuations: [Tile: CheckedContinuation<Void, Never>] = [:]
    private var startedTiles: Set<Tile> = []
    private var startCounts: [Tile: Int] = [:]
    private var canceledTiles: Set<Tile> = []
    private var preparedTiles: Set<Tile> = []
    private var materializedTiles: Set<Tile> = []
    private var materializeCounts: [Tile: Int] = [:]
    private var materializeFlags: [Tile: [Bool]] = [:]
    private var revalidatedTiles: Set<Tile> = []
    private var saveStartedTiles: Set<Tile> = []
    private var savedETags: [Tile: String?] = [:]
    private var removedFromDiskTiles: Set<Tile> = []
    private var diskEntries: [Tile: String?] = [:]
    private var downloadContinuations: [Tile: CheckedContinuation<TileDownloader.DownloadResult, Never>] = [:]
    private var prepareContinuations: [Tile: CheckedContinuation<PreparedTileLoadResult?, Never>] = [:]
    private var materializeContinuations: [Tile: CheckedContinuation<PreparedTileMaterializeOutcome, Never>] = [:]
    private var saveContinuations: [Tile: CheckedContinuation<Void, Never>] = [:]

    init(suspendsSaves: Bool = false, suspendsDiskReads: Bool = false) {
        self.suspendsSaves = suspendsSaves
        self.suspendsDiskReads = suspendsDiskReads
    }

    // Registers a prepared-tile entry "on disk": `etag` is the stored source
    // ETag (nil models an entry saved from a server response without one).
    func setDiskEntry(_ tile: Tile, etag: String?) {
        lock.lock()
        diskEntries[tile] = etag
        lock.unlock()
    }

    func hasRemovedFromDisk(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return removedFromDiskTiles.contains(tile)
    }

    func savedETag(for tile: Tile) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return savedETags[tile]
    }

    func materializeCount(for tile: Tile) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return materializeCounts[tile, default: 0]
    }

    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileDiskCacheHit? {
        if suspendsDiskReads, hasDiskEntry(tile) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                recordDiskReadStarted(tile: tile, continuation: continuation)
            }
        }
        return diskEntryHit(tile: tile, matchingETag: matchingETag)
    }

    private func hasDiskEntry(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return diskEntries[tile] != nil
    }

    private func recordDiskReadStarted(tile: Tile, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        diskReadStartedTiles.insert(tile)
        diskReadContinuations[tile] = continuation
        lock.unlock()
    }

    func completeDiskRead(_ tile: Tile) {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        continuation = diskReadContinuations.removeValue(forKey: tile)
        lock.unlock()
        continuation?.resume()
    }

    func hasDiskReadStarted(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return diskReadStartedTiles.contains(tile)
    }

    func waitUntilDiskReadStarted(_ tile: Tile) async -> Bool {
        for _ in 0..<100 {
            if hasDiskReadStarted(tile) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func diskEntryHit(tile: Tile, matchingETag: String?) -> PreparedTileDiskCacheHit? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedETag = diskEntries[tile] else {
            return nil
        }
        if let matchingETag, matchingETag != storedETag {
            return nil
        }
        return PreparedTileDiskCacheHit(image: Self.makeArenaImage(tile: tile),
                                        sourceETag: storedETag)
    }

    /// A structurally empty arena image: the mock's `materialize(image:)` is
    /// stubbed, so the payload never reaches the real factory.
    static func makeArenaImage(tile: Tile) -> PreparedTileArenaImage {
        let emptyMeta = PreparedTileArenaImage.TextLabelSetMeta(placementInputs: [],
                                                                glyphRunStyles: [],
                                                                poiIconRunStyles: [])
        return PreparedTileArenaImage(
            tile: tile,
            spans: [],
            arenaByteCount: 0,
            textLabelsFull: emptyMeta,
            textLabelsReduced: emptyMeta,
            textLabelsMinimal: emptyMeta,
            roadLabels: PreparedTileArenaImage.RoadLabelsMeta(pathInputs: [],
                                                              pathRanges: [],
                                                              pathLabels: [],
                                                              labelStyle: nil,
                                                              glyphBounds: [],
                                                              glyphBoundRanges: [],
                                                              sizes: [],
                                                              anchorRanges: [],
                                                              anchors: []),
            blob: .inline(Data())
        )
    }

    func download(tile: Tile) async -> TileDownloader.DownloadResult {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                recordDownloadStarted(tile: tile, continuation: continuation)
            }
        }, onCancel: {
            recordDownloadCanceled(tile)
        })
    }

    func savePreparedOnDisk(tile: Tile,
                            preparedTile _: PreparedTileCPU,
                            plan _: TileArenaImagePlan?,
                            sourceETag: String?) async {
        recordSavedETag(tile: tile, sourceETag: sourceETag)
        guard suspendsSaves else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            saveStartedTiles.insert(tile)
            saveContinuations[tile] = continuation
            lock.unlock()
        }
    }

    func removePreparedFromDisk(tile: Tile) {
        lock.lock()
        removedFromDiskTiles.insert(tile)
        // Mirror the real cache: a removed pair stops being served.
        diskEntries[tile] = nil
        lock.unlock()
    }

    private func recordSavedETag(tile: Tile, sourceETag: String?) {
        lock.lock()
        savedETags[tile] = sourceETag
        lock.unlock()
    }

    func prepare(tile: Tile, data _: Data) async -> PreparedTileLoadResult? {
        await withCheckedContinuation { continuation in
            recordPrepareStarted(tile: tile, continuation: continuation)
        }
    }

    func materialize(preparedTile: PreparedTileCPU,
                     plan _: TileArenaImagePlan?,
                     awaitingRevalidation: Bool) async -> PreparedTileMaterializeOutcome {
        recordMaterializeFlag(tile: preparedTile.tile, awaitingRevalidation: awaitingRevalidation)
        return await withCheckedContinuation { continuation in
            recordMaterializeStarted(tile: preparedTile.tile, continuation: continuation)
        }
    }

    func materialize(image: PreparedTileArenaImage,
                     awaitingRevalidation: Bool) async -> PreparedTileMaterializeOutcome {
        recordMaterializeFlag(tile: image.tile, awaitingRevalidation: awaitingRevalidation)
        return await withCheckedContinuation { continuation in
            recordMaterializeStarted(tile: image.tile, continuation: continuation)
        }
    }

    func markRevalidated(tile: Tile) async {
        recordRevalidated(tile: tile)
    }

    private func recordRevalidated(tile: Tile) {
        lock.lock()
        revalidatedTiles.insert(tile)
        lock.unlock()
    }

    private func recordMaterializeFlag(tile: Tile, awaitingRevalidation: Bool) {
        lock.lock()
        materializeFlags[tile, default: []].append(awaitingRevalidation)
        lock.unlock()
    }

    func hasRevalidated(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revalidatedTiles.contains(tile)
    }

    func materializeFlagHistory(for tile: Tile) -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return materializeFlags[tile, default: []]
    }

    func parse(tile _: Tile, data _: Data) async -> Bool {
        false
    }

    func hasStarted(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedTiles.contains(tile)
    }

    func startCount(for tile: Tile) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return startCounts[tile, default: 0]
    }

    func hasSaveStarted(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveStartedTiles.contains(tile)
    }

    func wasCanceled(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceledTiles.contains(tile)
    }

    func hasPrepared(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return preparedTiles.contains(tile)
    }

    func hasMaterialized(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return materializedTiles.contains(tile)
    }

    func completeDownload(_ tile: Tile, result: TileDownloader.DownloadResult) {
        let continuation: CheckedContinuation<TileDownloader.DownloadResult, Never>?
        lock.lock()
        continuation = downloadContinuations.removeValue(forKey: tile)
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func completePrepare(_ tile: Tile, timings: [TileParseLayerTiming] = []) {
        let continuation: CheckedContinuation<PreparedTileLoadResult?, Never>?
        lock.lock()
        continuation = prepareContinuations.removeValue(forKey: tile)
        lock.unlock()
        continuation?.resume(returning: PreparedTileLoadResult(preparedTile: Self.makePreparedTile(tile: tile),
                                                               parseLayerTimings: timings))
    }

    func completePrepareFailing(_ tile: Tile) {
        let continuation: CheckedContinuation<PreparedTileLoadResult?, Never>?
        lock.lock()
        continuation = prepareContinuations.removeValue(forKey: tile)
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    /// Boolean convenience for the many tests that only distinguish success
    /// from a transient failure; false maps to `.allocationOrStoreFailed`.
    func completeMaterialize(_ tile: Tile, result: Bool) {
        completeMaterialize(tile, outcome: result ? .materialized : .allocationOrStoreFailed)
    }

    func completeMaterialize(_ tile: Tile, outcome: PreparedTileMaterializeOutcome) {
        let continuation: CheckedContinuation<PreparedTileMaterializeOutcome, Never>?
        lock.lock()
        continuation = materializeContinuations.removeValue(forKey: tile)
        lock.unlock()
        continuation?.resume(returning: outcome)
    }

    func completeSave(_ tile: Tile) {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        continuation = saveContinuations.removeValue(forKey: tile)
        lock.unlock()
        continuation?.resume()
    }

    func waitUntilStarted(_ tile: Tile, attempts: Int = 100) async -> Bool {
        for _ in 0..<attempts {
            if hasStarted(tile) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilStartCount(_ count: Int, for tile: Tile) async -> Bool {
        for _ in 0..<100 {
            if startCount(for: tile) >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilSaveStarted(_ tile: Tile) async -> Bool {
        for _ in 0..<100 {
            if hasSaveStarted(tile) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilPrepared(_ tile: Tile) async -> Bool {
        for _ in 0..<100 {
            if hasPrepared(tile) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilMaterializeCount(_ count: Int, for tile: Tile) async -> Bool {
        for _ in 0..<100 {
            if materializeCount(for: tile) >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilMaterialized(_ tile: Tile) async -> Bool {
        for _ in 0..<100 {
            if hasMaterialized(tile) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func recordDownloadStarted(
        tile: Tile,
        continuation: CheckedContinuation<TileDownloader.DownloadResult, Never>
    ) {
        lock.lock()
        startedTiles.insert(tile)
        startCounts[tile, default: 0] += 1
        downloadContinuations[tile] = continuation
        lock.unlock()
    }

    private func recordPrepareStarted(
        tile: Tile,
        continuation: CheckedContinuation<PreparedTileLoadResult?, Never>
    ) {
        lock.lock()
        preparedTiles.insert(tile)
        prepareContinuations[tile] = continuation
        lock.unlock()
    }

    private func recordMaterializeStarted(
        tile: Tile,
        continuation: CheckedContinuation<PreparedTileMaterializeOutcome, Never>
    ) {
        lock.lock()
        materializedTiles.insert(tile)
        materializeCounts[tile, default: 0] += 1
        materializeContinuations[tile] = continuation
        lock.unlock()
    }

    private func recordDownloadCanceled(_ tile: Tile) {
        let continuation: CheckedContinuation<TileDownloader.DownloadResult, Never>?
        lock.lock()
        canceledTiles.insert(tile)
        continuation = downloadContinuations.removeValue(forKey: tile)
        lock.unlock()
        continuation?.resume(returning: .failure(.network))
    }

    private static func makePreparedTile(tile: Tile) -> PreparedTileCPU {
        let emptyGeometry = PreparedTileCPU.GeometryLayer(vertices: [],
                                                         indices: [],
                                                         styles: [],
                                                         overviewStyleMasks: [])
        let emptyRoadPhases = RoadGeometryPhases(shadow: emptyGeometry,
                                                 casing: emptyGeometry,
                                                 fill: emptyGeometry,
                                                 detail: emptyGeometry,
                                                 overlay: emptyGeometry)

        let emptyTextLabelSet = PreparedTileCPU.TextLabelSet(placementInputs: [],
                                                             glyphRuns: [],
                                                             poiIconRuns: [])
        return PreparedTileCPU(tile: tile,
                               ground: emptyGeometry,
                               roads: RoadStructureBuckets(tunnel: emptyRoadPhases,
                                                          ground: emptyRoadPhases,
                                                          bridge: emptyRoadPhases),
                               bridgeOverlay: emptyGeometry,
                               extruded: PreparedTileCPU.Extruded(vertices: [],
                                                                  indices: [],
                                                                  styles: []),
                               textLabels: PreparedTileCPU.TextLabels(full: emptyTextLabelSet,
                                                                       reduced: emptyTextLabelSet,
                                                                       minimal: emptyTextLabelSet),
                               roadLabels: PreparedTileCPU.RoadLabels(pathInputs: [],
                                                                      pathRanges: [],
                                                                      pathLabels: [],
                                                                      labelStyle: nil,
                                                                      localGlyphVertices: [],
                                                                      glyphBounds: [],
                                                                      glyphBoundRanges: [],
                                                                      sizes: [],
                                                                      anchorRanges: [],
                                                                      anchors: []))
    }
}
