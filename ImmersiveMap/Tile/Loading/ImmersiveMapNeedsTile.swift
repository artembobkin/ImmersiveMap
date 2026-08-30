// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import MetalKit

// Business purpose:
// Tile loading orchestrator for the current map frame.
// Accepts the up-to-date set of needed tiles, puts deferred requests into a
// deduplicated FIFO and drives each tile through a three-stage pipeline:
// a disk stage (the prepared cache answers without the network), a network
// stage (download) and a CPU stage (parse/materialize/save), separate Tasks
// with independent concurrency limits so that disk reads are not gated by
// network slots, a slow network does not occupy parse slots, and long
// parsing does not block download starts.
// A disk hit is final: freshness comes from the prepared cache's TTL and its
// identity namespace (style, source, labels, format version), so a served
// tile ends its load without a request or an ETag comparison. Only a miss,
// or an entry that cannot be materialized, continues to the network.
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

    // Default disk-stage limit. The file read itself is serialized on the
    // prepared cache's shared IO queue, so slots only buy overlap of the
    // per-tile decode (LZFSE, plist, checksum) and materialize; half the
    // cores capped at 4 keeps a warm lane from starving the parse slots it
    // shares the E-cores with.
    static let defaultMaxConcurrentDiskLoads = max(2, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4))

    // Tile lifecycle stage within the pipeline. Transitions happen only on `stateQueue`.
    private enum LoadStage {
        case disk           // disk Task is reading/materializing, occupies a disk slot
        case networkQueued  // past the disk stage, holds no slot: waiting for a
                            // network slot in `queuedNetworkWork`, or finishing after a hit
        case network        // network Task is downloading the tile, occupies a network slot
        case cpuQueued      // downloaded, waiting for a free CPU slot
        case cpu            // CPU Task is parsing/materializing, occupies a CPU slot
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

    // A tile past the disk stage waiting for a free network slot.
    private struct QueuedNetworkWork {
        let tile: Tile
        let generation: UInt64
    }

    private var ongoingTasks: [Tile: OngoingTask] = [:]
    // The tile's position in the latest request(): the smaller, the closer to the camera.
    // Determines selection from the CPU-stage queue.
    private var wantedTilePriorities: [Tile: Int] = [:]
    private var nextTaskGeneration: UInt64 = 1
    private let maxConcurrentFetches: Int
    private let maxConcurrentPrepares: Int
    private let maxConcurrentDiskLoads: Int
    // Whether loads enter through the disk stage. Off when the pipeline has
    // no prepared disk cache: a guaranteed miss per tile buys nothing.
    private let usesDiskStage: Bool
    private var diskInFlightCount = 0
    private var networkInFlightCount = 0
    private var cpuInFlightCount = 0
    private var queuedNetworkWork: [QueuedNetworkWork] = []
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
                     geometryTransport: any PreparedTileGeometryTransporting,
                     tileTraceRecorder: TileTraceRecorder,
                     tileLoadingStatusReporter: TileLoadingStatusReporter?) {
        self.init(config: config,
                  loadPipeline: DefaultTileLoadPipeline(tileRenderStore: tileRenderStore,
                                                        config: config,
                                                        preparedTileCacheIdentity: preparedTileCacheIdentity,
                                                        geometryTransport: geometryTransport),
                  tileTraceRecorder: tileTraceRecorder,
                  tileLoadingStatusReporter: tileLoadingStatusReporter)
    }

    // Base initializer with explicit pipeline/policy injection (also used in tests).
    init(config: ImmersiveMapSettings,
         loadPipeline: TileLoadPipeline,
         retryPolicy: RetryPolicy = .default,
         maxConcurrentPrepares: Int = ImmersiveMapNeedsTile.defaultMaxConcurrentPrepares,
         maxConcurrentDiskLoads: Int = ImmersiveMapNeedsTile.defaultMaxConcurrentDiskLoads,
         now: @escaping () -> Date = Date.init,
         retryWakeScheduler: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, workItem in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
         },
         tileTraceRecorder: TileTraceRecorder = TileTraceRecorder(),
         tileLoadingStatusReporter: TileLoadingStatusReporter? = nil) {
        self.maxConcurrentFetches = config.tiles.network.maxConcurrentFetches
        self.maxConcurrentPrepares = max(1, maxConcurrentPrepares)
        self.maxConcurrentDiskLoads = max(1, maxConcurrentDiskLoads)
        self.usesDiskStage = loadPipeline.hasPreparedDiskCache
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
            dropUnwantedQueuedNetworkWorkLocked()

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

        let entryLaneInFlightCount = usesDiskStage ? diskInFlightCount : networkInFlightCount
        let entryLaneLimit = usesDiskStage ? maxConcurrentDiskLoads : maxConcurrentFetches
        if entryLaneInFlightCount >= entryLaneLimit {
            pendingTilesQueue.enqueue(tile)
            tileTraceRecorder.record(.tileSchedulerEnqueued(tile, inFlight: entryLaneInFlightCount))
            return
        }

        createLoadTileTaskLocked(tile: tile)
    }

    // Tiles parked between stages (past the disk stage, waiting for a network
    // slot) are dropped when demand leaves them: they hold no slot and no
    // bytes, and a fast pan over a cold area must not download every tile
    // that was wanted for a single frame (their unstarted siblings die in
    // pendingTilesQueue.clear() the same way). A later request runs the whole
    // chain again, disk stage first.
    // Must be called only from within `stateQueue`.
    private func dropUnwantedQueuedNetworkWorkLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        queuedNetworkWork.removeAll { work in
            guard ongoingTasks[work.tile]?.generation == work.generation,
                  ongoingTasks[work.tile]?.stage == .networkQueued else {
                return true
            }
            if wantedTiles.contains(work.tile) {
                return false
            }
            ongoingTasks.removeValue(forKey: work.tile)
            tileLoadingStatusReporter?.recordLoadDropped(tile: work.tile)
            tileTraceRecorder.record(.tileLoadDropped(work.tile))
            return true
        }
    }

    // Creates the entry-stage async task (disk, or network when no prepared
    // cache exists) and registers the tile as in-flight.
    // Must be called only from within `stateQueue`.
    private func createLoadTileTaskLocked(tile: Tile) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        tileLoadingStatusReporter?.recordLoadScheduled(tile: tile)
        let generation = nextTaskGeneration
        nextTaskGeneration &+= 1
        // .utility: without an explicit priority the task would inherit the render
        // thread's user-interactive QoS, and CPU-bound parsing would compete with
        // rendering for the P-cores.
        let task: Task<Void, Never>
        let entryStage: LoadStage
        if usesDiskStage {
            entryStage = .disk
            diskInFlightCount += 1
            task = Task(priority: .utility) {
                await self.runDiskStage(tile: tile, generation: generation)
            }
        } else {
            entryStage = .network
            networkInFlightCount += 1
            task = Task(priority: .utility) {
                await self.runNetworkStage(tile: tile, generation: generation)
            }
        }
        ongoingTasks[tile] = OngoingTask(generation: generation, task: task, stage: entryStage)
        tileTraceRecorder.record(.tileLoadScheduled(
            tile,
            inFlight: usesDiskStage ? diskInFlightCount : networkInFlightCount
        ))
    }

    // Disk stage: asks the prepared cache before the network. A hit is final
    // (freshness is the cache's TTL and identity namespace), so the load ends
    // here without a download; a miss, or an entry that cannot be
    // materialized, releases the disk slot and continues to the network stage
    // with its own slots. The read and its materialize are one "disk" stage
    // in the status report.
    private func runDiskStage(tile: Tile, generation: UInt64) async {
        var served = false
        if Task.isCancelled == false,
           recordCurrentTaskEvent(tile: tile, generation: generation, event: {
               tileLoadingStatusReporter?.recordLoadStarted(tile: tile)
               tileTraceRecorder.record(.tileLoadStart(tile))
               tileLoadingStatusReporter?.recordDiskStarted(tile: tile)
               tileTraceRecorder.record(.tileDiskLookupStart(tile))
           }) {
            let signposter = MapSignposts.tiles
            let signpostState = signposter.beginInterval("tileDiskRead",
                                                         id: signposter.makeSignpostID(),
                                                         "\(tile.z)/\(tile.x)/\(tile.y)")
            let hit = await loadPipeline.requestPreparedDiskCached(tile: tile, matchingETag: nil)
            signposter.endInterval("tileDiskRead", signpostState)
            if Task.isCancelled == false {
                if let hit {
                    // runMaterialize owns the cleanup of an unreadable pair,
                    // behind the generation gate; nil means cancelled or
                    // superseded, and then nothing is recorded either.
                    let outcome = await materializeDiskImage(hit.image,
                                                             expectedTile: tile,
                                                             generation: generation,
                                                             reportsMaterializationStages: false)
                    served = outcome == .materialized
                    if let outcome {
                        recordCurrentTaskEvent(tile: tile, generation: generation, event: {
                            if outcome == .materialized {
                                tileLoadingStatusReporter?.recordDiskServed(tile: tile)
                                tileTraceRecorder.record(.tileDiskHit(tile))
                            } else {
                                tileLoadingStatusReporter?.recordDiskMissed(tile: tile)
                                let reason = outcome == .imageUnreadable
                                    ? "image_unreadable"
                                    : "materialize_failed"
                                tileTraceRecorder.record(.tileDiskMiss(tile, reason: reason))
                            }
                        })
                    }
                } else {
                    recordCurrentTaskEvent(tile: tile, generation: generation, event: {
                        tileLoadingStatusReporter?.recordDiskMissed(tile: tile)
                        tileTraceRecorder.record(.tileDiskMiss(tile, reason: "no_entry"))
                    })
                }
            }
        }
        if served {
            _ = markLoadSucceeded(tile: tile, generation: generation, source: "prepared_disk")
        }
        let isCurrent = releaseDiskSlot(tile: tile, generation: generation)

        var isNetworkStageScheduled = false
        if isCurrent, served == false, Task.isCancelled == false {
            isNetworkStageScheduled = scheduleNetworkStage(tile: tile, generation: generation)
        }
        if isNetworkStageScheduled == false {
            Task { @MainActor in
                self.finishLoading(tile: tile, generation: generation)
            }
        }
    }

    // Frees the tile's disk slot and immediately starts the next tile from
    // the pending queue (which feeds the disk lane while it exists).
    // Returns false if the task is already stale (cancelAll or replacement).
    private func releaseDiskSlot(tile: Tile, generation: UInt64) -> Bool {
        stateQueue.sync {
            guard ongoingTasks[tile]?.generation == generation,
                  ongoingTasks[tile]?.stage == .disk else {
                return false
            }
            ongoingTasks[tile]?.stage = .networkQueued
            diskInFlightCount = max(0, diskInFlightCount - 1)
            startNextPendingLoadLocked()
            return true
        }
    }

    // Schedules the network stage after a disk miss: starts immediately if a
    // network slot is free, otherwise parks the tile in `queuedNetworkWork`.
    // Returns false if the tile is already stale.
    private func scheduleNetworkStage(tile: Tile, generation: UInt64) -> Bool {
        stateQueue.sync {
            guard ongoingTasks[tile]?.generation == generation,
                  ongoingTasks[tile]?.stage == .networkQueued else {
                return false
            }
            if networkInFlightCount < maxConcurrentFetches {
                startNetworkStageLocked(tile: tile, generation: generation)
            } else {
                queuedNetworkWork.append(QueuedNetworkWork(tile: tile, generation: generation))
            }
            return true
        }
    }

    // Creates the network-stage async task and occupies a network slot.
    // Must be called only from within `stateQueue`.
    private func startNetworkStageLocked(tile: Tile, generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        networkInFlightCount += 1
        ongoingTasks[tile]?.stage = .network
        let task = Task(priority: .utility) {
            await self.runNetworkStage(tile: tile, generation: generation)
        }
        // The tile's current Task is swapped: cancelAll must cancel the live
        // stage; the disk task has already finished by this point.
        ongoingTasks[tile]?.task = task
    }

    // Starts parked network work while free slots remain, discarding stale
    // entries. Selection is by current demand priority, like the CPU queue.
    // Must be called only from within `stateQueue`.
    private func startNextQueuedNetworkWorkLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        while networkInFlightCount < maxConcurrentFetches, queuedNetworkWork.isEmpty == false {
            queuedNetworkWork.removeAll { work in
                ongoingTasks[work.tile]?.generation != work.generation
                    || ongoingTasks[work.tile]?.stage != .networkQueued
            }
            guard let bestIndex = queuedNetworkWork.indices.min(by: { lhs, rhs in
                priorityRankLocked(of: queuedNetworkWork[lhs].tile) < priorityRankLocked(of: queuedNetworkWork[rhs].tile)
            }) else {
                return
            }
            let work = queuedNetworkWork.remove(at: bestIndex)
            startNetworkStageLocked(tile: work.tile, generation: work.generation)
        }
    }

    // Network stage: downloads the tile and frees the network slot right
    // after the download, without waiting for parsing. Entered directly when
    // no prepared disk cache exists, otherwise only after a disk miss.
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
            if usesDiskStage == false {
                tileTraceRecorder.record(.tileLoadStart(tile))
            }
            tileLoadingStatusReporter?.recordNetworkStarted(tile: tile)
        }) else {
            return nil
        }
        let signposter = MapSignposts.tiles
        let signpostState = signposter.beginInterval("tileDownload",
                                                     id: signposter.makeSignpostID(),
                                                     "\(tile.z)/\(tile.x)/\(tile.y)")
        let downloadResult = await loadPipeline.download(tile: tile)
        signposter.endInterval("tileDownload", signpostState)
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
            if usesDiskStage {
                // The pending FIFO feeds the disk lane; a freed network slot
                // serves the tiles already past their disk miss.
                startNextQueuedNetworkWorkLocked()
            } else {
                startNextPendingLoadLocked()
            }
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
                startCPUStageLocked(tile: tile,
                                    generation: generation,
                                    downloadResult: downloadResult)
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
            await self.runCPUStage(tile: tile,
                                   generation: generation,
                                   downloadResult: downloadResult)
        }
        // The tile's current Task is swapped: cancelAll must cancel the live
        // stage; the network task has already finished by this point.
        ongoingTasks[tile]?.task = task
    }

    private func runCPUStage(tile: Tile,
                             generation: UInt64,
                             downloadResult: TileDownloader.DownloadResult) async {
        let signposter = MapSignposts.tiles
        let signpostState = signposter.beginInterval("tileParse",
                                                     id: signposter.makeSignpostID(),
                                                     "\(tile.z)/\(tile.x)/\(tile.y)")
        await processDownloadResult(tile: tile,
                                    generation: generation,
                                    downloadResult: downloadResult)
        signposter.endInterval("tileParse", signpostState)
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

    // CPU stage: prepared cache by exact ETag -> parse -> materialize -> save.
    // Runs only after a disk miss (or with the prepared cache off), so the
    // ETag-matched lookup exists for one case: a second engine sharing the
    // namespace (the video export next to the live map) saved the entry
    // between our miss and our download completing. Honors task cancellation
    // at every step and updates the retry state based on the outcome.
    private func processDownloadResult(tile: Tile,
                                       generation: UInt64,
                                       downloadResult: TileDownloader.DownloadResult) async {
        if Task.isCancelled {
            return
        }

        switch downloadResult {
        case let .success(data, etag):
            // Reuse a prepared tile only when the server provided an ETag and
            // it matches the one the entry was derived from: that proves the
            // entry was parsed from the exact bytes just downloaded.
            if let etag,
               let cached = await loadPipeline.requestPreparedDiskCached(tile: tile, matchingETag: etag) {
                if Task.isCancelled {
                    return
                }
                if await materializeDiskImage(cached.image,
                                              expectedTile: tile,
                                              generation: generation) == .materialized {
                    _ = markLoadSucceeded(tile: tile,
                                          generation: generation,
                                          source: "prepared_disk_etag")
                    return
                }
                // A failed materialize of the matching entry falls through to
                // parsing the downloaded bytes. Disk cleanup is owned by
                // materializeDiskImage: it removes the pair only for a
                // genuinely unreadable image, behind the generation gate; a
                // transient allocation failure keeps the healthy entry.
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
                // Any pair on disk was already judged by the disk stage; a
                // parse failure of fresh bytes says nothing about it, and
                // deleting here could snipe an entry a second engine saved
                // moments ago. Staleness is bounded by the cache TTL.
                markLoadFailed(tile: tile, generation: generation, reason: .parseFailed)
                return
            }
            if Task.isCancelled {
                return
            }
            // One plan for the whole tail of the load: the GPU materialize
            // writes it into the tile's backing buffer and the disk save
            // encodes it into the cached blob, so the span measure walk and
            // the index narrowing run once instead of twice.
            let plan = TileArenaImageMath.plan(for: preparedFromNetwork.preparedTile)
            let materializedFromNetwork = await materializePreparedTile(
                preparedFromNetwork.preparedTile,
                plan: plan,
                expectedTile: tile,
                generation: generation
            ) == .materialized
            if Task.isCancelled {
                return
            }
            if materializedFromNetwork {
                // The tile is already on screen (materialize invalidated the
                // frame); encoding and compressing the prepared payload costs
                // tens of milliseconds, so the retry/status bookkeeping of
                // markLoadSucceeded runs first instead of waiting behind it.
                // The save stays on this task: the parse slot is held until it
                // finishes, and cancellation does not abort it (the encode is
                // synchronous and the write completes on the IO queue).
                guard markLoadSucceeded(tile: tile,
                                        generation: generation,
                                        source: "network") else {
                    return
                }
                await loadPipeline.savePreparedOnDisk(tile: tile,
                                                      preparedTile: preparedFromNetwork.preparedTile,
                                                      plan: plan,
                                                      sourceETag: etag)
            } else {
                markLoadFailed(tile: tile, generation: generation, reason: .parseFailed)
            }
        case let .failure(downloadFailure):
            // The disk stage already answered what the disk could; a failed
            // download has nothing to fall back on. The retry backoff re-runs
            // the whole chain, disk stage first, which also covers an entry
            // another engine saves meanwhile.
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

    /// Disk-hit materialize. On a genuinely unreadable image (corrupt blob,
    /// checksum mismatch, or span table, not cancellation and not memory
    /// pressure) the entry is removed, mirroring the codec's cleanup of
    /// corrupt metadata one stage earlier, so a broken pair cannot fail
    /// every retry forever.
    private func materializeDiskImage(_ image: PreparedTileArenaImage,
                                      expectedTile: Tile,
                                      generation: UInt64,
                                      reportsMaterializationStages: Bool = true) async -> PreparedTileMaterializeOutcome? {
        await runMaterialize(tile: expectedTile,
                             generation: generation,
                             tileMatchesExpected: image.tile == expectedTile,
                             reportsMaterializationStages: reportsMaterializationStages) {
            await loadPipeline.materialize(image: image)
        }
    }

    private func materializePreparedTile(_ preparedTile: PreparedTileCPU,
                                         plan: TileArenaImagePlan?,
                                         expectedTile: Tile,
                                         generation: UInt64) async -> PreparedTileMaterializeOutcome? {
        await runMaterialize(tile: expectedTile,
                             generation: generation,
                             tileMatchesExpected: preparedTile.tile == expectedTile,
                             reportsMaterializationStages: true) {
            await loadPipeline.materialize(preparedTile: preparedTile,
                                           plan: plan)
        }
    }

    /// Shared wrapper of both materialize flavors: honors cancellation, runs
    /// the generation-gated started/succeeded/failed reporting around the
    /// operation, and owns the disk cleanup. Removal fires only for
    /// `.imageUnreadable` (a corrupt entry), never for the transient
    /// `.allocationOrStoreFailed`, and only behind the generation gate: a
    /// superseded task that read a corrupt entry must not delete the fresh
    /// pair its replacement may have just saved. Returns nil when the task
    /// was cancelled or superseded mid-flight.
    /// `reportsMaterializationStages` is false for the disk stage, whose
    /// whole read-and-materialize is one "disk" stage in the status report.
    private func runMaterialize(tile: Tile,
                                generation: UInt64,
                                tileMatchesExpected: Bool,
                                reportsMaterializationStages: Bool,
                                operation: () async -> PreparedTileMaterializeOutcome) async -> PreparedTileMaterializeOutcome? {
        if Task.isCancelled {
            return nil
        }
        guard tileMatchesExpected else {
            return nil
        }
        guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
            if reportsMaterializationStages {
                tileLoadingStatusReporter?.recordMaterializationStarted(tile: tile)
            }
        }) else {
            return nil
        }
        let outcome = await operation()
        if Task.isCancelled {
            return nil
        }
        guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
            guard reportsMaterializationStages else {
                return
            }
            if outcome == .materialized {
                tileLoadingStatusReporter?.recordMaterializationSucceeded(tile: tile)
            } else {
                tileLoadingStatusReporter?.recordMaterializationFailed(tile: tile,
                                                                       reason: "materialize_failed")
            }
        }) else {
            return nil
        }
        if outcome == .imageUnreadable {
            loadPipeline.removePreparedFromDisk(tile: tile)
        }
        return outcome
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

    // Starts the next suitable tile from the pending queue in the freed
    // entry-lane slot (disk, or network when no prepared cache exists).
    // Must be called only from within `stateQueue`.
    private func startNextPendingLoadLocked() {
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
            queuedNetworkWork.removeAll()
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
            diskInFlightCount = 0
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
