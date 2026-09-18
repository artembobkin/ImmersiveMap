// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation

/// The loader's test doubles, shared by every test that drives
/// `ImmersiveMapNeedsTile` by hand: a wake scheduler that records instead of
/// arming timers, and a pipeline whose every stage is a continuation the
/// test completes when it decides to.

final class RecordingRetryWakeScheduler {
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

    /// The wakes still armed: the loader replaces an armed wake with an
    /// earlier one by cancelling it (the stage watchdog arms one at every
    /// stage start, a retry window usually comes sooner), so a test that
    /// wants the wake a failure armed looks here, not at the first entry.
    var liveWakes: [ScheduledWake] {
        scheduledWakes.filter { $0.workItem.isCancelled == false }
    }

    func schedule(delay: TimeInterval, workItem: DispatchWorkItem) {
        lock.lock()
        wakes.append(ScheduledWake(delay: delay, workItem: workItem))
        lock.unlock()
    }

    func waitUntilScheduledCount(_ count: Int) async -> Bool {
        for _ in 0..<500 {
            if scheduledWakes.count >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

final class ControlledTileLoadPipeline: TileLoadPipeline, @unchecked Sendable {
    private let suspendsSaves: Bool
    private let suspendsDiskReads: Bool
    let hasPreparedDiskCache: Bool
    private let lock = NSLock()
    private var diskReadStartedTiles: Set<Tile> = []
    private var diskReadCounts: [Tile: Int] = [:]
    private var diskReadContinuations: [Tile: [CheckedContinuation<Void, Never>]] = [:]
    private var startedTiles: Set<Tile> = []
    private var startCounts: [Tile: Int] = [:]
    private var canceledTiles: Set<Tile> = []
    private var preparedTiles: Set<Tile> = []
    private var materializedTiles: Set<Tile> = []
    private var materializeCounts: [Tile: Int] = [:]
    private var saveStartedTiles: Set<Tile> = []
    private var savedETags: [Tile: String?] = [:]
    private var removedFromDiskTiles: Set<Tile> = []
    private var diskEntries: [Tile: String?] = [:]
    private var downloadContinuations: [Tile: CheckedContinuation<TileDownloader.DownloadResult, Never>] = [:]
    private var prepareContinuations: [Tile: CheckedContinuation<PreparedTileLoadResult?, Never>] = [:]
    private var materializeContinuations: [Tile: CheckedContinuation<PreparedTileMaterializeOutcome, Never>] = [:]
    // A completion that arrives before its stage has started is held and
    // delivered the moment the stage registers, in order. The loader runs its
    // stages on child tasks (the disk serve and the download concurrently),
    // so a test that completes one stage and immediately completes the next
    // races the scheduler: on a loaded runner the second stage had not yet
    // suspended on its continuation, the completion was dropped, and the
    // scenario deadlocked into cascading assertion failures (seen on
    // testAllocationFailureOnETagMatchedEntryKeepsTheDiskPair in CI, never
    // natively). Holding it makes a test's completions order-independent.
    private var pendingDownloadResults: [Tile: [TileDownloader.DownloadResult]] = [:]
    private var pendingPrepareResults: [Tile: [PreparedTileLoadResult?]] = [:]
    private var pendingMaterializeOutcomes: [Tile: [PreparedTileMaterializeOutcome]] = [:]
    private var saveContinuations: [Tile: CheckedContinuation<Void, Never>] = [:]

    init(suspendsSaves: Bool = false,
         suspendsDiskReads: Bool = false,
         hasPreparedDiskCache: Bool = true) {
        self.suspendsSaves = suspendsSaves
        self.suspendsDiskReads = suspendsDiskReads
        self.hasPreparedDiskCache = hasPreparedDiskCache
    }

    // Registers a prepared-tile entry "on disk": `etag` is the stored source
    // ETag (nil models an entry saved from a server response without one).
    func setDiskEntry(_ tile: Tile, etag: String?) {
        lock.lock()
        diskEntries[tile] = etag
        lock.unlock()
    }

    func isPreparedOnDisk(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return diskEntries[tile] != nil
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

    // Counts and (optionally) suspends only the disk-stage reads
    // (matchingETag == nil); the CPU stage's ETag-matched lookups pass
    // through so a test controls one lane at a time.
    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileDiskCacheHit? {
        if matchingETag == nil {
            if suspendsDiskReads {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    recordDiskRead(tile: tile, holding: continuation)
                }
            } else {
                recordDiskRead(tile: tile, holding: nil)
            }
        }
        return diskEntryHit(tile: tile, matchingETag: matchingETag)
    }

    /// Registers the read and, when suspending, its continuation in one lock
    /// acquisition: a test that observed the count may complete the read
    /// immediately, and a resume must never race the registration.
    private func recordDiskRead(tile: Tile, holding continuation: CheckedContinuation<Void, Never>?) {
        lock.lock()
        diskReadStartedTiles.insert(tile)
        diskReadCounts[tile, default: 0] += 1
        if let continuation {
            diskReadContinuations[tile, default: []].append(continuation)
        }
        lock.unlock()
    }

    func completeDiskRead(_ tile: Tile) {
        var continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        if var held = diskReadContinuations[tile], held.isEmpty == false {
            continuation = held.removeFirst()
            diskReadContinuations[tile] = held.isEmpty ? nil : held
        }
        lock.unlock()
        continuation?.resume()
    }

    func diskReadCount(for tile: Tile) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return diskReadCounts[tile, default: 0]
    }

    func waitUntilDiskReadCount(_ count: Int, for tile: Tile) async -> Bool {
        for _ in 0..<500 {
            if diskReadCount(for: tile) >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func hasDiskReadStarted(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return diskReadStartedTiles.contains(tile)
    }

    func waitUntilDiskReadStarted(_ tile: Tile) async -> Bool {
        for _ in 0..<500 {
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
            groundStyleRuns: [],
            textLabels: emptyMeta,
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
                     plan _: TileArenaImagePlan?) async -> PreparedTileMaterializeOutcome {
        await withCheckedContinuation { continuation in
            recordMaterializeStarted(tile: preparedTile.tile, continuation: continuation)
        }
    }

    func materialize(image: PreparedTileArenaImage) async -> PreparedTileMaterializeOutcome {
        await withCheckedContinuation { continuation in
            recordMaterializeStarted(tile: image.tile, continuation: continuation)
        }
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
        if continuation == nil {
            pendingDownloadResults[tile, default: []].append(result)
        }
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func completePrepare(_ tile: Tile, timings: [TileParseLayerTiming] = []) {
        completePrepare(tile, result: PreparedTileLoadResult(preparedTile: Self.makePreparedTile(tile: tile),
                                                             parseLayerTimings: timings))
    }

    func completePrepareFailing(_ tile: Tile) {
        completePrepare(tile, result: nil)
    }

    private func completePrepare(_ tile: Tile, result: PreparedTileLoadResult?) {
        let continuation: CheckedContinuation<PreparedTileLoadResult?, Never>?
        lock.lock()
        continuation = prepareContinuations.removeValue(forKey: tile)
        if continuation == nil {
            pendingPrepareResults[tile, default: []].append(result)
        }
        lock.unlock()
        continuation?.resume(returning: result)
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
        if continuation == nil {
            pendingMaterializeOutcomes[tile, default: []].append(outcome)
        }
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

    func waitUntilStarted(_ tile: Tile, attempts: Int = 500) async -> Bool {
        for _ in 0..<attempts {
            if hasStarted(tile) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilStartCount(_ count: Int, for tile: Tile) async -> Bool {
        for _ in 0..<500 {
            if startCount(for: tile) >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilSaved(_ tile: Tile) async -> Bool {
        for _ in 0..<500 {
            if savedETag(for: tile) != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilSaveStarted(_ tile: Tile) async -> Bool {
        for _ in 0..<500 {
            if hasSaveStarted(tile) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilPrepared(_ tile: Tile) async -> Bool {
        for _ in 0..<500 {
            if hasPrepared(tile) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilMaterializeCount(_ count: Int, for tile: Tile) async -> Bool {
        for _ in 0..<500 {
            if materializeCount(for: tile) >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilMaterialized(_ tile: Tile) async -> Bool {
        for _ in 0..<500 {
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
        let pending = Self.takeFirstPending(&pendingDownloadResults, tile)
        if pending == nil {
            downloadContinuations[tile] = continuation
        }
        lock.unlock()
        if let pending {
            continuation.resume(returning: pending)
        }
    }

    private func recordPrepareStarted(
        tile: Tile,
        continuation: CheckedContinuation<PreparedTileLoadResult?, Never>
    ) {
        lock.lock()
        preparedTiles.insert(tile)
        let pending = Self.takeFirstPending(&pendingPrepareResults, tile)
        if pending == nil {
            prepareContinuations[tile] = continuation
        }
        lock.unlock()
        if let pending {
            continuation.resume(returning: pending)
        }
    }

    private func recordMaterializeStarted(
        tile: Tile,
        continuation: CheckedContinuation<PreparedTileMaterializeOutcome, Never>
    ) {
        lock.lock()
        materializedTiles.insert(tile)
        materializeCounts[tile, default: 0] += 1
        let pending = Self.takeFirstPending(&pendingMaterializeOutcomes, tile)
        if pending == nil {
            materializeContinuations[tile] = continuation
        }
        lock.unlock()
        if let pending {
            continuation.resume(returning: pending)
        }
    }

    /// Pops the oldest held completion for the tile, if any. Must run under
    /// `lock`.
    private static func takeFirstPending<Value>(_ pending: inout [Tile: [Value]], _ tile: Tile) -> Value? {
        guard var queue = pending[tile], queue.isEmpty == false else {
            return nil
        }
        let first = queue.removeFirst()
        pending[tile] = queue.isEmpty ? nil : queue
        return first
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
                                                          automobileGround: emptyRoadPhases,
                                                          bridge: emptyRoadPhases),
                               bridgeOverlay: emptyGeometry,
                               extruded: PreparedTileCPU.Extruded(vertices: [],
                                                                  indices: [],
                                                                  styles: []),
                               textLabels: emptyTextLabelSet,
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
