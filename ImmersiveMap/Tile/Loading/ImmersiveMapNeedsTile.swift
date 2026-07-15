// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import MetalKit

// Бизнес-назначение:
// Оркестратор загрузки тайлов для текущего кадра карты.
// Принимает актуальный набор нужных тайлов, ограничивает параллелизм,
// ставит отложенные запросы в deduplicated FIFO и запускает
// загрузку/парс через `TileLoadPipeline`.
// Решения о том, когда запрос тайла временно блокируется после ошибок, делегируются
// в `TileRetryController` (per-tile backoff + глобальный cooldown).
/// Потокобезопасен (`@unchecked Sendable`): мутабельное состояние загрузчика
/// сериализовано `stateQueue`, задачи загрузки работают из фоновых Task.
final class ImmersiveMapNeedsTile: @unchecked Sendable {
    typealias RetryPolicy = TileRetryController.Policy

    private struct OngoingTask {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private var ongoingTasks: [Tile: OngoingTask] = [:]
    private var nextTaskGeneration: UInt64 = 1
    private let maxConcurrentFetches: Int
    private let pendingTilesQueue: DeduplicatedTilesFIFO
    private var wantedTiles: Set<Tile> = []
    private let loadPipeline: TileLoadPipeline
    private let retryController: TileRetryController
    private let tileTraceRecorder: TileTraceRecorder
    private let tileLoadingStatusReporter: TileLoadingStatusReporter?
    private let stateQueue = DispatchQueue(label: "ImmersiveMap.ImmersiveMapNeedsTile.state")

    /// Вызывается на main queue, когда истекает ближайшее retry-окно.
    /// Рендер on-demand: после провала загрузки кадры кончаются, пер-кадровый
    /// `request()` больше не выполняется, и без внешнего пинка backoff истекает
    /// «в тишине» - дыра на месте тайла висит до следующего жеста. Владелец
    /// обязан по этому колбэку запросить кадр.
    var onRetryWindowExpired: (() -> Void)?
    private var retryWakeWorkItem: DispatchWorkItem?
    private var retryWakeDeadline: Date?
    private let now: () -> Date
    private let retryWakeScheduler: (TimeInterval, DispatchWorkItem) -> Void
    
    // Production-конструктор: собирает стандартный pipeline (диск + сеть + парс в TileRenderStore).
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

    // Базовый конструктор с явной инъекцией pipeline/политики (используется и в тестах).
    init(config: ImmersiveMapSettings,
         loadPipeline: TileLoadPipeline,
         retryPolicy: RetryPolicy = .default,
         now: @escaping () -> Date = Date.init,
         retryWakeScheduler: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, workItem in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
         },
         tileTraceRecorder: TileTraceRecorder = TileTraceRecorder(),
         tileLoadingStatusReporter: TileLoadingStatusReporter? = nil) {
        self.maxConcurrentFetches = config.tiles.network.maxConcurrentFetches
        self.pendingTilesQueue = DeduplicatedTilesFIFO(capacity: config.tiles.network.pendingRequestQueueCapacity)
        self.loadPipeline = loadPipeline
        self.retryController = TileRetryController(policy: retryPolicy, now: now)
        self.now = now
        self.retryWakeScheduler = retryWakeScheduler
        self.tileTraceRecorder = tileTraceRecorder
        self.tileLoadingStatusReporter = tileLoadingStatusReporter
    }
    
    // Обновляет актуальный набор тайлов для кадра: очищает pending-очередь
    // и заново планирует загрузку нужных тайлов в приоритетном порядке.
    // Уже начатые загрузки не отменяются при кратком выпадении из demand:
    // результат всё равно попадет в кэш и не даст пограничным тайлам
    // зациклиться в состоянии loading/fallback.
    func request(tiles: [Tile]) {
        // Дедупликация с сохранением исходного порядка `tiles`: порядок важен для приоритета загрузки.
        // Отдельный `wanted` как Set нужен для O(1) проверок актуальности тайла.
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

            pendingTilesQueue.clear()
            retryController.retainOnly(tiles: wantedTiles)

            // Планируем весь batch внутри одного lock, чтобы не делать sync на каждый тайл.
            for tile in deduplicatedTiles {
                requestSingleTileLocked(tile: tile)
            }
        }
    }
    
    // Внутренняя версия планирования без lock-обертки.
    // Должна вызываться только изнутри `stateQueue`.
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

        if ongoingTasks.count >= maxConcurrentFetches {
            pendingTilesQueue.enqueue(tile)
            tileTraceRecorder.record(.tileSchedulerEnqueued(tile, inFlight: ongoingTasks.count))
            return
        }

        createLoadTileTaskLocked(tile: tile)
    }

    // Создает async-задачу загрузки тайла и регистрирует ее как in-flight.
    // Должна вызываться только изнутри `stateQueue`.
    private func createLoadTileTaskLocked(tile: Tile) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        tileLoadingStatusReporter?.recordLoadScheduled(tile: tile)
        let generation = nextTaskGeneration
        nextTaskGeneration &+= 1
        // .utility: без явного приоритета задача унаследовала бы user-interactive QoS
        // рендер-потока, и CPU-bound парсинг конкурировал бы с рендером за P-ядра.
        let task = Task(priority: .utility) {
            await loadTile(tile: tile, generation: generation)
        }
        ongoingTasks[tile] = OngoingTask(generation: generation, task: task)
        tileTraceRecorder.record(.tileLoadScheduled(tile, inFlight: ongoingTasks.count))
    }
    
    // Полный цикл загрузки тайла: сеть (URLCache) -> prepared-кэш по ETag -> парс ->
    // materialize -> сохранение. prepared-кэш ключуется по ETag сырого тайла, поэтому
    // текущий ETag узнаём из загрузки (URLCache делает её дешёвой) и только затем
    // решаем - переиспользовать распарсенный тайл или парсить заново.
    // На любом этапе учитывает отмену задачи и обновляет retry-state по результату.
    private func loadTile(tile: Tile, generation: UInt64) async {
        if Task.isCancelled {
            return
        }
        guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
            tileLoadingStatusReporter?.recordLoadStarted(tile: tile)
            tileTraceRecorder.record(.tileLoadStart(tile))
        }) else {
            return
        }
        defer {
            Task { @MainActor in
                finishLoading(tile: tile, generation: generation)
            }
        }

        await proceedToNetwork(tile: tile, generation: generation)
    }

    private func proceedToNetwork(tile: Tile, generation: UInt64) async {
        if Task.isCancelled {
            return
        }

        guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
            tileLoadingStatusReporter?.recordNetworkStarted(tile: tile)
        }) else {
            return
        }
        let downloadResult = await loadPipeline.download(tile: tile)
        if Task.isCancelled {
            return
        }

        switch downloadResult {
        case let .success(data, etag):
            guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
                tileLoadingStatusReporter?.recordNetworkSucceeded(tile: tile,
                                                                  bytes: data.count)
                tileTraceRecorder.record(.tileDownloadSuccess(tile, bytes: data.count))
            }) else {
                return
            }

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
            let failureDescription = Self.downloadFailureDescription(downloadFailure)
            guard recordCurrentTaskEvent(tile: tile, generation: generation, event: {
                tileLoadingStatusReporter?.recordNetworkFailed(tile: tile,
                                                               reason: failureDescription)
                tileTraceRecorder.record(.tileDownloadFailed(tile,
                                                             reason: failureDescription))
            }) else {
                return
            }

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

    // Завершает in-flight загрузку тайла и пытается запустить следующий подходящий тайл из pending-очереди.
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

            while let popped = pendingTilesQueue.dequeue() {
                if wantedTiles.contains(popped), ongoingTasks[popped] == nil {
                    requestSingleTileLocked(tile: popped)
                    break
                }
            }
        }
    }

    // Полностью останавливает scheduler: очищает wanted/pending/retry-state и отменяет все in-flight задачи.
    func cancelAll() {
        stateQueue.sync {
            wantedTiles.removeAll()
            pendingTilesQueue.clear()
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
        }
    }

    // Фиксирует успешную загрузку тайла: сбрасывает retry-state для этого тайла.
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

    // Фиксирует неуспешную загрузку тайла: обновляет backoff/cooldown через retry-контроллер
    // и взводит будильник к истечению ближайшего retry-окна.
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

    // Взводит одноразовый будильник к `wakeAt`; более ранний уже взведённый
    // будильник поглощает поздние (после срабатывания он перевзводится на
    // следующее оставшееся окно).
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
            // Окна позже сработавшего могли быть поглощены его deadline -
            // перевзводимся на ближайшее оставшееся. Уже истекшие окна ретраит
            // кадр, который запросит владелец по колбэку.
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
