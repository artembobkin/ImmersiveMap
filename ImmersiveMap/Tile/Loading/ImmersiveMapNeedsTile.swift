// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import MetalKit

// Business purpose:
// Tile loading orchestrator for the current map frame.
// Accepts the up-to-date set of needed tiles, puts deferred requests into a
// deduplicated FIFO and drives each tile through a two-stage pipeline:
// a network stage (download) and a CPU stage (prepared cache/parse/materialize),
// separate Tasks with independent concurrency limits so that a slow network
// does not occupy parse slots and long parsing does not block download starts.
// Decisions about when a tile request is temporarily blocked after errors are
// delegated to `TileRetryController` (per-tile backoff + global cooldown).
/// Thread-safe (`@unchecked Sendable`): the loader's mutable state is
/// serialized by `stateQueue`; loading work runs from background Tasks.
final class ImmersiveMapNeedsTile: @unchecked Sendable {
    typealias RetryPolicy = TileRetryController.Policy

    // Default CPU-stage limit. Parsing runs at utility QoS and effectively
    // executes on E-cores, so the ceiling is tied to the core count rather
    // than to network slots.
    static let defaultMaxConcurrentPrepares = max(2, min(ProcessInfo.processInfo.activeProcessorCount - 2, 6))

    // Tile lifecycle stage within the pipeline. Transitions happen only on `stateQueue`.
    private enum LoadStage {
        case network    // network Task is downloading the tile, occupies a network slot
        case cpuQueued  // downloaded, waiting for a free CPU slot
        case cpu        // CPU Task is parsing/materializing, occupies a CPU slot
    }

    private struct OngoingTask {
        let generation: UInt64
        var task: Task<Void, Never>
        var stage: LoadStage
    }

    // A downloaded tile waiting for a free CPU slot.
    private struct QueuedCPUWork {
        let tile: Tile
        let generation: UInt64
        let downloadResult: TileDownloader.DownloadResult
    }

    private var ongoingTasks: [Tile: OngoingTask] = [:]
    // The tile's position in the latest request(): the smaller, the closer to the camera.
    // Determines selection from the CPU-stage queue.
    private var wantedTilePriorities: [Tile: Int] = [:]
    private var nextTaskGeneration: UInt64 = 1
    private let maxConcurrentFetches: Int
    private let maxConcurrentPrepares: Int
    private var networkInFlightCount = 0
    private var cpuInFlightCount = 0
    private var queuedCPUWork: [QueuedCPUWork] = []
    private let pendingTilesQueue: DeduplicatedTilesFIFO
    private var wantedTiles: Set<Tile> = []
    private let loadPipeline: TileLoadPipeline
    private let retryController: TileRetryController
    private let tileTraceRecorder: TileTraceRecorder
    private let tileLoadingStatusReporter: TileLoadingStatusReporter?
    private let stateQueue = DispatchQueue(label: "ImmersiveMap.ImmersiveMapNeedsTile.state")

    /// Called on the main queue when the nearest retry window expires.
    /// Rendering is on-demand: after a failed download the frames stop, the
    /// per-frame `request()` no longer runs, and without an external kick the
    /// backoff expires "in silence": the hole where the tile should be hangs
    /// until the next gesture. The owner must request a frame on this callback.
    var onRetryWindowExpired: (() -> Void)?
    private var retryWakeWorkItem: DispatchWorkItem?
    private var retryWakeDeadline: Date?
    private let now: () -> Date
    private let retryWakeScheduler: (TimeInterval, DispatchWorkItem) -> Void
    
    // Production initializer: assembles the standard pipeline (disk + network + parse into TileRenderStore).
    convenience init(tileRenderStore: TileRenderStore,
                     config: ImmersiveMapSettings,
                     preparedTileCacheIdentity: PreparedTileCacheIdentity,
                     tileTraceRecorder: TileTraceRecorder,
                     tileLoadingStatusReporter: TileLoadingStatusReporter?) {
        self.init(config: config,
                  loadPipeline: DefaultTileLoadPipeline(tileRenderStore: tileRenderStore,
                                                        config: config,
                                                        preparedTileCacheIdentity: preparedTileCacheIdentity),
                  tileTraceRecorder: tileTraceRecorder,
                  tileLoadingStatusReporter: tileLoadingStatusReporter)
    }

    // Base initializer with explicit pipeline/policy injection (also used in tests).
    init(config: ImmersiveMapSettings,
         loadPipeline: TileLoadPipeline,
         retryPolicy: RetryPolicy = .default,
         maxConcurrentPrepares: Int = ImmersiveMapNeedsTile.defaultMaxConcurrentPrepares,
         now: @escaping () -> Date = Date.init,
         retryWakeScheduler: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, workItem in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
         },
         tileTraceRecorder: TileTraceRecorder = TileTraceRecorder(),
         tileLoadingStatusReporter: TileLoadingStatusReporter? = nil) {
        self.maxConcurrentFetches = config.tiles.network.maxConcurrentFetches
        self.maxConcurrentPrepares = max(1, maxConcurrentPrepares)
        self.pendingTilesQueue = DeduplicatedTilesFIFO(capacity: config.tiles.network.pendingRequestQueueCapacity)
        self.loadPipeline = loadPipeline
        self.retryController = TileRetryController(policy: retryPolicy, now: now)
        self.now = now
        self.retryWakeScheduler = retryWakeScheduler
        self.tileTraceRecorder = tileTraceRecorder
        self.tileLoadingStatusReporter = tileLoadingStatusReporter
    }
    
    // Updates the current tile set for the frame: clears the pending queue
    // and reschedules loading of the needed tiles in priority order.
    // Already started downloads are not cancelled on a brief drop out of demand:
    // the result still lands in the cache and keeps borderline tiles from
    // looping in the loading/fallback state.
    func request(tiles: [Tile]) {
        // Deduplication preserving the original `tiles` order: the order matters for load priority.
        // A separate `wanted` Set is needed for O(1) tile relevance checks.
        var deduplicatedTiles: [Tile] = []
        deduplicatedTiles.reserveCapacity(tiles.count)
        var seenTiles: Set<Tile> = []
        for tile in tiles {
            if seenTiles.insert(tile).inserted {
                deduplicatedTiles.append(tile)
            }
        }
        let wanted = Set(deduplicatedTiles)

        stateQueue.sync {
            tileLoadingStatusReporter?.recordDemand(input: tiles.count,
                                                    deduplicated: deduplicatedTiles.count,
                                                    tiles: deduplicatedTiles)
            tileTraceRecorder.record(.tileSchedulerRequest(input: tiles.count,
                                                           deduplicated: deduplicatedTiles.count))
            wantedTiles = wanted
            wantedTilePriorities = Dictionary(uniqueKeysWithValues: deduplicatedTiles.enumerated()
                .map { ($0.element, $0.offset) })

            pendingTilesQueue.clear()
            retryController.retainOnly(tiles: wantedTiles)

            // Schedule the whole batch inside one lock to avoid a sync per tile.
            for tile in deduplicatedTiles {
                requestSingleTileLocked(tile: tile)
            }
        }
    }
    
    // Internal scheduling variant without the lock wrapper.
    // Must be called only from within `stateQueue`.
    private func requestSingleTileLocked(tile: Tile) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if wantedTiles.contains(tile) == false {
            return
        }
        if ongoingTasks[tile] != nil {
            tileTraceRecorder.record(.tileSchedulerAlreadyLoading(tile))
            return
        }
        if retryController.shouldBlock(tile: tile) {
            tileTraceRecorder.record(.tileSchedulerRetryBlocked(tile))
            return
        }

        if networkInFlightCount >= maxConcurrentFetches {
            pendingTilesQueue.enqueue(tile)
            tileTraceRecorder.record(.tileSchedulerEnqueued(tile, inFlight: networkInFlightCount))
            return
        }

        createLoadTileTaskLocked(tile: tile)
    }

    // Creates the network-stage async task and registers the tile as in-flight.
    // Must be called only from within `stateQueue`.
    private func createLoadTileTaskLocked(tile: Tile) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        tileLoadingStatusReporter?.recordLoadScheduled(tile: tile)
        let generation = nextTaskGeneration
        nextTaskGeneration &+= 1
        // .utility: without an explicit priority the task would inherit the render
        // thread's user-interactive QoS, and CPU-bound parsing would compete with
        // rendering for the P-cores.
        let task = Task(priority: .utility) {
            await self.runNetworkStage(tile: tile, generation: generation)
        }
        ongoingTasks[tile] = OngoingTask(generation: generation, task: task, stage: .network)
        networkInFlightCount += 1
        tileTraceRecorder.record(.tileLoadScheduled(tile, inFlight: networkInFlightCount))
    }

    // Network stage: downloads the tile and frees the network slot right after
    // the download, without waiting for parsing. The continuation (prepared
    // cache/parse/materialize) goes to a separate CPU task with its own concurrency limit.
    private func runNetworkStage(tile: Tile, generation: UInt64) async {
        let downloadResult = await downloadStage(tile: tile, generation: generation)
        let isCurrent = releaseNetworkSlot(tile: tile, generation: generation)

        var isCPUStageScheduled = false
        if isCurrent, let downloadResult, Task.isCancelled == false {
            isCPUStageScheduled = scheduleCPUStage(tile: tile,
                                                   generation: generation,
                                                   downloadResult: downloadResult)
        }
        if isCPUStageScheduled == false {
            Task { @MainActor in
                self.finishLoading(tile: tile, generation: generation)
            }
        }
    }

    // Performs the download honoring cancellation and records the reporter's network events.
    // Returns nil if the task is cancelled or already stale.
    private func downloadStage(tile: Tile, generation: UInt64) async -> TileDownloader.DownloadResult? {
        if Task.isCancelled {
            return nil
        }
        guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
            tileLoadingStatusReporter?.recordLoadStarted(tile: tile)
            tileTraceRecorder.record(.tileLoadStart(tile))
            tileLoadingStatusReporter?.recordNetworkStarted(tile: tile)
        }) else {
            return nil
        }
        let downloadResult = await loadPipeline.download(tile: tile)
        if Task.isCancelled {
            return nil
        }

        switch downloadResult {
        case let .success(data, _):
            guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
                tileLoadingStatusReporter?.recordNetworkSucceeded(tile: tile,
                                                                  bytes: data.count)
                tileTraceRecorder.record(.tileDownloadSuccess(tile, bytes: data.count))
            }) else {
                return nil
            }
        case let .failure(downloadFailure):
            let failureDescription = Self.downloadFailureDescription(downloadFailure)
            guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
                tileLoadingStatusReporter?.recordNetworkFailed(tile: tile,
                                                               reason: failureDescription)
                tileTraceRecorder.record(.tileDownloadFailed(tile,
                                                             reason: failureDescription))
            }) else {
                return nil
            }
        }
        return downloadResult
    }

    // Frees the tile's network slot and immediately starts the next tile from the pending queue.
    // Returns false if the task is already stale (cancelAll or replacement).
    private func releaseNetworkSlot(tile: Tile, generation: UInt64) -> Bool {
        stateQueue.sync {
            guard ongoingTasks[tile]?.generation == generation,
                  ongoingTasks[tile]?.stage == .network else {
                return false
            }
            ongoingTasks[tile]?.stage = .cpuQueued
            networkInFlightCount = max(0, networkInFlightCount - 1)
            startNextPendingNetworkLoadLocked()
            return true
        }
    }

    // Schedules the CPU stage: starts immediately if a CPU slot is free, otherwise
    // queues the downloaded tile. Returns false if the tile is already stale.
    private func scheduleCPUStage(tile: Tile,
                                  generation: UInt64,
                                  downloadResult: TileDownloader.DownloadResult) -> Bool {
        stateQueue.sync {
            guard ongoingTasks[tile]?.generation == generation,
                  ongoingTasks[tile]?.stage == .cpuQueued else {
                return false
            }
            if cpuInFlightCount < maxConcurrentPrepares {
                startCPUStageLocked(tile: tile, generation: generation, downloadResult: downloadResult)
            } else {
                queuedCPUWork.append(QueuedCPUWork(tile: tile,
                                                   generation: generation,
                                                   downloadResult: downloadResult))
            }
            return true
        }
    }

    // Creates the CPU-stage async task and occupies a CPU slot.
    // Must be called only from within `stateQueue`.
    private func startCPUStageLocked(tile: Tile,
                                     generation: UInt64,
                                     downloadResult: TileDownloader.DownloadResult) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        cpuInFlightCount += 1
        ongoingTasks[tile]?.stage = .cpu
        let task = Task(priority: .utility) {
            await self.runCPUStage(tile: tile, generation: generation, downloadResult: downloadResult)
        }
        // The tile's current Task is swapped: cancelAll must cancel the live
        // stage; the network task has already finished by this point.
        ongoingTasks[tile]?.task = task
    }

    private func runCPUStage(tile: Tile,
                             generation: UInt64,
                             downloadResult: TileDownloader.DownloadResult) async {
        await processDownloadResult(tile: tile, generation: generation, downloadResult: downloadResult)
        releaseCPUSlot(tile: tile, generation: generation)
        Task { @MainActor in
            self.finishLoading(tile: tile, generation: generation)
        }
    }

    // Frees the tile's CPU slot and starts the next deferred CPU stage.
    private func releaseCPUSlot(tile: Tile, generation: UInt64) {
        stateQueue.sync {
            if ongoingTasks[tile]?.generation == generation, ongoingTasks[tile]?.stage == .cpu {
                cpuInFlightCount = max(0, cpuInFlightCount - 1)
            }
            startNextQueuedCPUWorkLocked()
        }
    }

    // Starts deferred CPU stages while free slots remain, discarding stale
    // entries (tile cancelled or replaced by a new generation).
    // Selection is not FIFO but by current demand priority: coarse distant
    // tiles download faster than detailed near ones and, in network completion
    // order, would systematically overtake them in the parse queue.
    private func startNextQueuedCPUWorkLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        while cpuInFlightCount < maxConcurrentPrepares, queuedCPUWork.isEmpty == false {
            queuedCPUWork.removeAll { work in
                ongoingTasks[work.tile]?.generation != work.generation
                    || ongoingTasks[work.tile]?.stage != .cpuQueued
            }
            guard let bestIndex = queuedCPUWork.indices.min(by: { lhs, rhs in
                priorityRankLocked(of: queuedCPUWork[lhs].tile) < priorityRankLocked(of: queuedCPUWork[rhs].tile)
            }) else {
                return
            }
            let work = queuedCPUWork.remove(at: bestIndex)
            startCPUStageLocked(tile: work.tile,
                                generation: work.generation,
                                downloadResult: work.downloadResult)
        }
    }

    // Tiles outside the current demand (briefly dropped out) are parsed last.
    private func priorityRankLocked(of tile: Tile) -> Int {
        wantedTilePriorities[tile] ?? Int.max
    }

    // CPU stage: prepared cache by ETag -> parse -> materialize -> save.
    // The prepared cache is keyed by the raw tile's ETag, so we learn the
    // current ETag from the network stage and only then decide whether to
    // reuse the parsed tile or parse from scratch. Honors task cancellation at
    // every step and updates the retry state based on the outcome.
    private func processDownloadResult(tile: Tile,
                                       generation: UInt64,
                                       downloadResult: TileDownloader.DownloadResult) async {
        if Task.isCancelled {
            return
        }

        switch downloadResult {
        case let .success(data, etag):
            // Reuse the prepared (parsed) tile only when the server provided an ETag
            // and it matches the one this prepared tile was derived from. Without an
            // ETag we cannot prove freshness, so we parse the bytes we just downloaded
            // rather than risk serving a stale prepared tile.
            if let etag,
               let cached = await loadPipeline.requestPreparedDiskCached(tile: tile, matchingETag: etag) {
                if Task.isCancelled {
                    return
                }
                if await materializePreparedTile(cached,
                                                 expectedTile: tile,
                                                 generation: generation) {
                    guard markLoadSucceeded(tile: tile,
                                            generation: generation,
                                            source: "prepared_disk") else {
                        return
                    }
                    return
                }
                // Keep a valid entry if we were merely cancelled; only a genuine
                // materialize failure invalidates it.
                if Task.isCancelled {
                    return
                }
                loadPipeline.removePreparedFromDisk(tile: tile)
            }
            if Task.isCancelled {
                return
            }

            guard let preparedFromNetwork = await prepareTile(data: data,
                                                              tile: tile,
                                                              generation: generation) else {
                if Task.isCancelled {
                    return
                }
                loadPipeline.removePreparedFromDisk(tile: tile)
                markLoadFailed(tile: tile, generation: generation, reason: .parseFailed)
                return
            }
            if Task.isCancelled {
                return
            }
            let materializedFromNetwork = await materializePreparedTile(
                preparedFromNetwork.preparedTile,
                expectedTile: tile,
                generation: generation
            )
            if Task.isCancelled {
                return
            }
            if materializedFromNetwork {
                await loadPipeline.savePreparedOnDisk(tile: tile,
                                                      preparedTile: preparedFromNetwork.preparedTile,
                                                      sourceETag: etag)
                if Task.isCancelled {
                    return
                }
                guard markLoadSucceeded(tile: tile,
                                        generation: generation,
                                        source: "network") else {
                    return
                }
            } else {
                loadPipeline.removePreparedFromDisk(tile: tile)
                markLoadFailed(tile: tile, generation: generation, reason: .parseFailed)
            }
        case let .failure(downloadFailure):
            // Offline / server error: render any cached prepared tile for this
            // coordinate, regardless of ETag, so a warm cache still shows content
            // without the network. materializePreparedTile returns false on
            // cancellation; a cancelled or superseded load must not mutate the
            // replacement task's retry state.
            if let cached = await loadPipeline.requestPreparedDiskCached(tile: tile, matchingETag: nil),
               await materializePreparedTile(cached,
                                             expectedTile: tile,
                                             generation: generation) {
                guard markLoadSucceeded(tile: tile,
                                        generation: generation,
                                        source: "prepared_disk_offline") else {
                    return
                }
                return
            }
            if Task.isCancelled {
                return
            }
            markLoadFailed(tile: tile,
                           generation: generation,
                           reason: .download(downloadFailure))
        }
    }

    private func prepareTile(data: Data,
                             tile: Tile,
                             generation: UInt64) async -> PreparedTileLoadResult? {
        if Task.isCancelled {
            return nil
        }
        guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
            tileLoadingStatusReporter?.recordParsingStarted(tile: tile)
        }) else {
            return nil
        }
        let result = await loadPipeline.prepare(tile: tile, data: data)
        if Task.isCancelled {
            return nil
        }
        guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
            if result == nil {
                tileLoadingStatusReporter?.recordParsingFailed(tile: tile,
                                                               reason: "parse_failed")
            } else {
                tileLoadingStatusReporter?.recordParsingSucceeded(
                    tile: tile,
                    layerTimings: result?.parseLayerTimings ?? []
                )
            }
        }) else {
            return nil
        }
        return result
    }

    private func materializePreparedTile(_ preparedTile: PreparedTileCPU,
                                         expectedTile: Tile,
                                         generation: UInt64) async -> Bool {
        if Task.isCancelled {
            return false
        }
        guard preparedTile.tile == expectedTile else {
            return false
        }
        guard recordCurrentTaskEvent(tile: expectedTile, generation: generation, event: {
            tileLoadingStatusReporter?.recordMaterializationStarted(tile: expectedTile)
        }) else {
            return false
        }
        let isMaterialized = await loadPipeline.materialize(preparedTile: preparedTile)
        if Task.isCancelled {
            return false
        }
        guard recordCurrentTaskEvent(tile: expectedTile, generation: generation, event: {
            if isMaterialized {
                tileLoadingStatusReporter?.recordMaterializationSucceeded(tile: expectedTile)
            } else {
                tileLoadingStatusReporter?.recordMaterializationFailed(tile: expectedTile,
                                                                      reason: "materialize_failed")
            }
        }) else {
            return false
        }
        return isMaterialized
    }

    @discardableResult
    private func recordCurrentTaskEvent(tile: Tile,
                                        generation: UInt64,
                                        event: () -> Void) -> Bool {
        stateQueue.sync {
            guard ongoingTasks[tile]?.generation == generation else {
                return false
            }
            event()
            return true
        }
    }

    // Ends the tile's lifecycle: removes it from the in-flight registry.
    // The slots have already been freed by the corresponding stage by this point.
    @MainActor
    private func finishLoading(tile: Tile, generation: UInt64) {
        #if DEBUG
        defer {
            onFinishLoadingAttemptForTesting?(tile)
        }
        #endif
        stateQueue.sync {
            guard ongoingTasks[tile]?.generation == generation else {
                return
            }
            ongoingTasks.removeValue(forKey: tile)
        }
    }

    // Starts the next suitable tile from the pending queue in the freed network slot.
    // Must be called only from within `stateQueue`.
    private func startNextPendingNetworkLoadLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        while let popped = pendingTilesQueue.dequeue() {
            if wantedTiles.contains(popped), ongoingTasks[popped] == nil {
                requestSingleTileLocked(tile: popped)
                break
            }
        }
    }

    // Fully stops the scheduler: clears wanted/pending/retry state and cancels all in-flight tasks.
    func cancelAll() {
        stateQueue.sync {
            wantedTiles.removeAll()
            wantedTilePriorities.removeAll()
            pendingTilesQueue.clear()
            queuedCPUWork.removeAll()
            retryController.reset()
            retryWakeWorkItem?.cancel()
            retryWakeWorkItem = nil
            retryWakeDeadline = nil
            let cancelledTiles = Array(ongoingTasks.keys)
            for ongoingTask in ongoingTasks.values {
                ongoingTask.task.cancel()
            }
            tileLoadingStatusReporter?.recordLoadsCancelled(tiles: cancelledTiles)
            ongoingTasks.removeAll()
            // Cancelled tasks do not decrement the counters (the generation no
            // longer matches), so the slots are freed here.
            networkInFlightCount = 0
            cpuInFlightCount = 0
        }
    }

    // Records a successful tile load: resets the retry state for this tile.
    private func markLoadSucceeded(tile: Tile,
                                   generation: UInt64,
                                   source: String) -> Bool {
        stateQueue.sync {
            guard ongoingTasks[tile]?.generation == generation else {
                return false
            }
            retryController.registerSuccess(for: tile)
            tileLoadingStatusReporter?.recordLoadCompleted(tile: tile)
            tileTraceRecorder.record(.tileLoadSuccess(tile, source: source))
            return true
        }
    }

    // Records a failed tile load: updates backoff/cooldown via the retry controller
    // and arms the alarm for the expiry of the nearest retry window.
    private func markLoadFailed(tile: Tile,
                                generation: UInt64,
                                reason: TileRetryFailureReason) {
        stateQueue.sync {
            guard ongoingTasks[tile]?.generation == generation else {
                return
            }
            retryController.registerFailure(for: tile, reason: reason)
            if let wakeAt = retryController.earliestNextRetryDate() {
                scheduleRetryWakeLocked(at: wakeAt)
            }
            tileLoadingStatusReporter?.recordLoadFailed(
                tile: tile,
                reason: Self.retryFailureDescription(reason)
            )
            tileTraceRecorder.record(.tileLoadFailed(
                tile,
                reason: Self.retryFailureDescription(reason)
            ))
        }
    }

    // Arms a one-shot alarm for `wakeAt`; an earlier already-armed alarm
    // absorbs later ones (after firing it re-arms for the next remaining
    // window).
    private func scheduleRetryWakeLocked(at wakeAt: Date) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if let retryWakeDeadline, retryWakeDeadline <= wakeAt {
            return
        }

        retryWakeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.retryWakeDidFire()
        }
        retryWakeWorkItem = workItem
        retryWakeDeadline = wakeAt
        retryWakeScheduler(max(0, wakeAt.timeIntervalSince(now())), workItem)
    }

    private func retryWakeDidFire() {
        var shouldNotify = false
        stateQueue.sync {
            retryWakeWorkItem = nil
            retryWakeDeadline = nil
            shouldNotify = wantedTiles.isEmpty == false
            // Windows later than the fired one may have been absorbed by its
            // deadline, so re-arm for the nearest remaining one. Already
            // expired windows are retried by the frame the owner requests via the callback.
            if let nextWakeAt = retryController.earliestNextRetryDate(), nextWakeAt > now() {
                scheduleRetryWakeLocked(at: nextWakeAt)
            }
        }
        if shouldNotify {
            onRetryWindowExpired?()
        }
    }

    #if DEBUG
    var onFinishLoadingAttemptForTesting: ((Tile) -> Void)?

    var tileLoadingStatusSnapshotForTesting: TileLoadingStatusSnapshot? {
        tileLoadingStatusReporter?.snapshot()
    }
    #endif

    private static func retryFailureDescription(_ reason: TileRetryFailureReason) -> String {
        switch reason {
        case .parseFailed:
            return "parse_failed"
        case let .download(downloadFailure):
            return downloadFailureDescription(downloadFailure)
        }
    }

    private static func downloadFailureDescription(_ failure: TileDownloader.DownloadFailure) -> String {
        switch failure {
        case .missingAuthorizationToken:
            return "missing_authorization_token"
        case .nonHTTPResponse:
            return "non_http_response"
        case .unauthorized:
            return "unauthorized"
        case .forbidden:
            return "forbidden"
        case .notFound:
            return "not_found"
        case .gone:
            return "gone"
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return "rate_limited(retry_after:\(retryAfter))"
            }
            return "rate_limited"
        case let .server(statusCode):
            return "server(\(statusCode))"
        case let .client(statusCode):
            return "client(\(statusCode))"
        case .emptyBody:
            return "empty_body"
        case .network:
            return "network"
        }
    }
}
