// Copyright (c) 2025-2026 Artem Bobkin.
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

        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3])))
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

        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3])))
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
        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3])))
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
        pipeline.completeDownload(tile, result: .success(Data([1, 2, 3])))
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
        pipeline.completeDownload(staleReadyTile, result: .success(Data([1, 2, 3])))
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

        // Первый тайл падает в T+0: окно T+0.5, будильник взведён на него.
        pipeline.completeDownload(firstTile, result: .failure(.network))
        let didScheduleFirst = await wakeScheduler.waitUntilScheduledCount(1)
        XCTAssertTrue(didScheduleFirst)

        // Второй падает в T+0.4: его окно T+0.9 поглощено более ранним deadline.
        now = Date(timeIntervalSince1970: 1000.4)
        pipeline.completeDownload(secondTile, result: .failure(.network))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Будильник срабатывает в T+0.6: окно первого тайла уже истекло и не
        // должно маскировать будущее окно второго - перевзвод на T+0.9.
        now = Date(timeIntervalSince1970: 1000.6)
        wakeScheduler.scheduledWakes[0].workItem.perform()

        let didRearm = await wakeScheduler.waitUntilScheduledCount(2)
        XCTAssertTrue(didRearm)
        XCTAssertEqual(wakeScheduler.scheduledWakes[1].delay, 0.3, accuracy: 0.001)
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

private final class ControlledTileLoadPipeline: TileLoadPipeline {
    private let lock = NSLock()
    private var startedTiles: Set<Tile> = []
    private var canceledTiles: Set<Tile> = []
    private var preparedTiles: Set<Tile> = []
    private var materializedTiles: Set<Tile> = []
    private var downloadContinuations: [Tile: CheckedContinuation<TileDownloader.DownloadResult, Never>] = [:]
    private var prepareContinuations: [Tile: CheckedContinuation<PreparedTileLoadResult?, Never>] = [:]
    private var materializeContinuations: [Tile: CheckedContinuation<Bool, Never>] = [:]

    func requestPreparedDiskCached(tile _: Tile) async -> PreparedTileCPU? {
        nil
    }

    func requestDiskCached(tile _: Tile) async -> Data? {
        nil
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

    func savePreparedOnDisk(tile _: Tile, preparedTile _: PreparedTileCPU) {}

    func saveOnDisk(tile _: Tile, data _: Data) {}

    func removePreparedFromDisk(tile _: Tile) {}

    func removeFromDisk(tile _: Tile) {}

    func prepare(tile: Tile, data _: Data) async -> PreparedTileLoadResult? {
        await withCheckedContinuation { continuation in
            recordPrepareStarted(tile: tile, continuation: continuation)
        }
    }

    func materialize(preparedTile: PreparedTileCPU) async -> Bool {
        await withCheckedContinuation { continuation in
            recordMaterializeStarted(tile: preparedTile.tile, continuation: continuation)
        }
    }

    func parse(tile _: Tile, data _: Data) async -> Bool {
        false
    }

    func hasStarted(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedTiles.contains(tile)
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

    func completeMaterialize(_ tile: Tile, result: Bool) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        continuation = materializeContinuations.removeValue(forKey: tile)
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func waitUntilStarted(_ tile: Tile) async -> Bool {
        for _ in 0..<100 {
            if hasStarted(tile) {
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
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        materializedTiles.insert(tile)
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
