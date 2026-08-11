// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Downloads map regions to disk and manages them, so maps render without a
/// network connection.
///
/// The controller is standalone: it is created with a tile provider and never
/// attaches to a map view. Downloaded tiles land in a store keyed by the tile
/// source identity, the same identity every `ImmersiveMapView` using that
/// provider derives on its own, so serving needs no wiring: with the default
/// `.automatic` offline mode the map falls back to downloaded regions whenever
/// a tile request fails, and `.offlineTileMode(.offlineOnly)` renders from
/// them without touching the network at all.
///
///     let offline = ImmersiveMapOfflineController(tileProvider: ImmersiveMapTilesProvider())
///     try offline.download(ImmersiveMapOfflineRegion(
///         id: "london",
///         southWest: GeoCoordinate(latitude: 51.35, longitude: -0.35),
///         northEast: GeoCoordinate(latitude: 51.65, longitude: 0.10),
///         zoomLevels: 0...14))
///
/// Progress is observable through `regions` and the `onRegionsChanged`
/// callback; both live on the main actor. Downloading an already stored
/// region fetches only what is missing, which is also how a cancelled or
/// interrupted download resumes.
///
/// Regions are stored in Application Support, not in a cache directory: they
/// stay until `removeRegion(regionID:)` or `removeAllRegions()` deletes them.
/// Tiles shared by overlapping regions are stored once and survive until the
/// last region referencing them is removed.
@MainActor
public final class ImmersiveMapOfflineController {
    /// Called after any region's status changes: download progress, completion,
    /// removal. Read `regions` for the new state.
    public var onRegionsChanged: (() -> Void)?

    /// All stored and downloading regions, sorted by id.
    public private(set) var regions: [ImmersiveMapOfflineRegionStatus] = []

    /// Upper bound on `download(_:)` region size, a guard against a region
    /// that would quietly try to mirror half the planet. Raise it consciously
    /// if a legitimately huge region is wanted.
    public var maximumTileCountPerDownload = 50_000

    private let store: OfflineTileStore
    private let maximumTileZoomLevel: Int?
    private let makeFetchTile: () -> OfflineRegionDownloader.FetchTile
    private let maxConcurrentFetches: Int
    private let pause: @Sendable (TimeInterval) async -> Void
    private let progressReportStride: Int
    // Created on first download: constructing the transport eagerly would fire
    // the TileJSON discovery request for a controller that only lists regions.
    private var fetchTile: OfflineRegionDownloader.FetchTile?
    private var records: [String: OfflineStoredRegionRecord] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var statuses: [String: ImmersiveMapOfflineRegionStatus] = [:]

    public convenience init<P: ImmersiveMapTileProvider>(tileProvider: P) {
        self.init(tileProvider: AnyImmersiveMapTileProvider(tileProvider))
    }

    public convenience init(tileProvider: AnyImmersiveMapTileProvider) {
        // Deriving the network settings through the same builder a map view
        // uses guarantees the store namespace matches what that map resolves.
        let config = ImmersiveMapSettings.default.tileProvider(tileProvider)
        self.init(network: config.tiles.network,
                  maximumTileZoomLevel: tileProvider.maximumTileZoomLevel,
                  makeFetchTile: {
                      let downloader = TileDownloader(config: config)
                      return { tile in await downloader.downloadResult(tile: tile) }
                  },
                  maxConcurrentFetches: config.tiles.network.maxConcurrentFetches)
    }

    init(network: ImmersiveMapSettings.TileSettings.NetworkSettings,
         maximumTileZoomLevel: Int?,
         baseDirectory: URL? = nil,
         makeFetchTile: @escaping () -> OfflineRegionDownloader.FetchTile,
         maxConcurrentFetches: Int = 5,
         pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         },
         progressReportStride: Int = 32) {
        self.store = OfflineTileStore(network: network, baseDirectory: baseDirectory)
        self.maximumTileZoomLevel = maximumTileZoomLevel
        self.makeFetchTile = makeFetchTile
        self.maxConcurrentFetches = maxConcurrentFetches
        self.pause = pause
        self.progressReportStride = progressReportStride
        loadPersistedRegions()
    }

    public func status(forRegionID id: String) -> ImmersiveMapOfflineRegionStatus? {
        statuses[id]
    }

    /// Starts (or resumes) downloading the region. Tiles already on disk are
    /// never refetched, so calling this again after a cancellation, an app
    /// relaunch, or a partial failure completes the region incrementally.
    /// Zoom levels above the provider's `maximumTileZoomLevel` are clamped
    /// away; the renderer never asks for them. A region that is already
    /// downloading is left alone.
    ///
    /// Throws `ImmersiveMapOfflineError` when the region is empty or covers
    /// more than `maximumTileCountPerDownload` tiles, and rethrows filesystem
    /// errors when the region record cannot be written.
    public func download(_ region: ImmersiveMapOfflineRegion) throws {
        guard downloadTasks[region.id] == nil else {
            return
        }
        let clampedRegion = region.clampingZoomLevels(toMaximum: maximumTileZoomLevel)
        let expectedTileCount = OfflineRegionTileMath.tileCount(in: clampedRegion)
        guard expectedTileCount > 0 else {
            throw ImmersiveMapOfflineError.emptyRegion
        }
        guard expectedTileCount <= maximumTileCountPerDownload else {
            throw ImmersiveMapOfflineError.regionTooLarge(tileCount: expectedTileCount,
                                                          maximumTileCount: maximumTileCountPerDownload)
        }

        let previousRecord = records[region.id]
        let record = OfflineStoredRegionRecord(region: clampedRegion,
                                               createdAt: previousRecord?.createdAt ?? Date(),
                                               isComplete: false,
                                               storedTileCount: 0,
                                               failedTileCount: 0,
                                               byteCount: 0)
        try store.writeRegionRecord(record)
        records[region.id] = record
        statuses[region.id] = ImmersiveMapOfflineRegionStatus(region: clampedRegion,
                                                              phase: .downloading,
                                                              expectedTileCount: expectedTileCount,
                                                              storedTileCount: 0,
                                                              failedTileCount: 0,
                                                              byteCount: 0)
        publishRegions()

        // Redefining a region under the same id can strand tiles only the old
        // bounds covered; they are pruned against the union of what remains.
        if let previousRegion = previousRecord?.region, previousRegion != clampedRegion {
            schedulePruneSweep(afterWaitingFor: [])
        }

        let regionID = clampedRegion.id
        let downloader = OfflineRegionDownloader(
            store: store,
            fetchTile: resolvedFetchTile(),
            maxConcurrentFetches: maxConcurrentFetches,
            pause: pause,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.applyProgress(progress, regionID: regionID)
                }
            },
            progressReportStride: progressReportStride)
        downloadTasks[regionID] = Task.detached(priority: .utility) { [weak self] in
            // Tile enumeration can be tens of thousands of values; it belongs
            // on this task, not on the main actor that spawned it.
            let tiles = OfflineRegionTileMath.tiles(in: clampedRegion)
            let outcome = await downloader.run(tiles: tiles)
            await self?.finishDownload(regionID: regionID, outcome: outcome)
        }
    }

    /// Stops the region's download between tiles. Everything already stored
    /// stays; the region reports `.incomplete` and `download(_:)` resumes it.
    public func cancelDownload(regionID: String) {
        downloadTasks[regionID]?.cancel()
    }

    /// Cancels any running download and deletes the region. Tiles also
    /// covered by another stored region are kept for that region.
    public func removeRegion(regionID: String) {
        guard records[regionID] != nil else {
            return
        }
        let activeTask = downloadTasks[regionID]
        activeTask?.cancel()
        records[regionID] = nil
        statuses[regionID] = nil
        store.removeRegionRecord(id: regionID)
        schedulePruneSweep(afterWaitingFor: activeTask.map { [$0] } ?? [])
        publishRegions()
    }

    /// Cancels every download and deletes every region and tile of this
    /// controller's tile source.
    public func removeAllRegions() {
        let activeTasks = Array(downloadTasks.values)
        activeTasks.forEach { $0.cancel() }
        for id in records.keys {
            store.removeRegionRecord(id: id)
        }
        records = [:]
        statuses = [:]
        schedulePruneSweep(afterWaitingFor: activeTasks)
        publishRegions()
    }

    // MARK: - Private

    private func loadPersistedRegions() {
        var incompleteRecords: [OfflineStoredRegionRecord] = []
        for record in store.regionRecords() {
            records[record.region.id] = record
            statuses[record.region.id] = ImmersiveMapOfflineRegionStatus(
                region: record.region,
                phase: record.isComplete ? .complete : .incomplete,
                expectedTileCount: OfflineRegionTileMath.tileCount(in: record.region),
                storedTileCount: record.storedTileCount,
                failedTileCount: record.failedTileCount,
                byteCount: record.byteCount)
            if record.isComplete == false {
                incompleteRecords.append(record)
            }
        }
        publishRegions(notify: false)

        // An interrupted download has no final record write, so its persisted
        // counters undercount what is actually on disk. Recount in the
        // background and fold the truth back in.
        guard incompleteRecords.isEmpty == false else {
            return
        }
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            for record in incompleteRecords {
                let tiles = OfflineRegionTileMath.tiles(in: record.region)
                let measured = store.measureStoredTiles(of: tiles)
                await self?.applyMeasuredCounts(regionID: record.region.id,
                                                storedTileCount: measured.storedTileCount,
                                                byteCount: measured.byteCount)
            }
        }
    }

    private func applyMeasuredCounts(regionID: String, storedTileCount: Int, byteCount: Int64) {
        guard let status = statuses[regionID], status.phase == .incomplete else {
            return
        }
        statuses[regionID] = ImmersiveMapOfflineRegionStatus(
            region: status.region,
            phase: storedTileCount == status.expectedTileCount ? .complete : .incomplete,
            expectedTileCount: status.expectedTileCount,
            storedTileCount: storedTileCount,
            failedTileCount: status.failedTileCount,
            byteCount: byteCount)
        publishRegions()
    }

    private func applyProgress(_ progress: OfflineRegionDownloader.Progress, regionID: String) {
        guard let status = statuses[regionID], status.phase == .downloading else {
            return
        }
        statuses[regionID] = ImmersiveMapOfflineRegionStatus(region: status.region,
                                                             phase: .downloading,
                                                             expectedTileCount: progress.expectedTileCount,
                                                             storedTileCount: progress.storedTileCount,
                                                             failedTileCount: progress.failedTileCount,
                                                             byteCount: progress.byteCount)
        publishRegions()
    }

    private func finishDownload(regionID: String, outcome: OfflineRegionDownloader.Outcome) {
        downloadTasks[regionID] = nil
        // The region may have been removed while the download was winding
        // down; writing the record back would resurrect it.
        guard var record = records[regionID] else {
            return
        }
        let progress = outcome.progress
        let isComplete: Bool
        if case .complete = outcome {
            isComplete = true
        } else {
            isComplete = false
        }
        record.isComplete = isComplete
        record.storedTileCount = progress.storedTileCount
        record.failedTileCount = progress.failedTileCount
        record.byteCount = progress.byteCount
        records[regionID] = record
        try? store.writeRegionRecord(record)
        statuses[regionID] = ImmersiveMapOfflineRegionStatus(region: record.region,
                                                             phase: isComplete ? .complete : .incomplete,
                                                             expectedTileCount: progress.expectedTileCount,
                                                             storedTileCount: progress.storedTileCount,
                                                             failedTileCount: progress.failedTileCount,
                                                             byteCount: progress.byteCount)
        publishRegions()
    }

    /// Prunes tiles no remaining region covers, first waiting out cancelled
    /// downloads whose in-flight tiles could otherwise land after the sweep.
    /// The kept set is read at sweep time, not capture time, so a download
    /// started between scheduling and sweeping keeps its tiles.
    private func schedulePruneSweep(afterWaitingFor activeTasks: [Task<Void, Never>]) {
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            for task in activeTasks {
                await task.value
            }
            // A gone controller means teardown: leaving files behind is safer
            // than sweeping against an unknowable region set.
            guard let keptRegions = await self?.regionsForPruneSweep() else {
                return
            }
            if keptRegions.isEmpty {
                store.removeEverything()
                return
            }
            var keptTiles = Set<Tile>()
            for region in keptRegions {
                keptTiles.formUnion(OfflineRegionTileMath.tileSet(in: region))
            }
            store.pruneTiles(keeping: keptTiles)
        }
    }

    private func regionsForPruneSweep() -> [ImmersiveMapOfflineRegion] {
        records.values.map(\.region)
    }

    private func resolvedFetchTile() -> OfflineRegionDownloader.FetchTile {
        if let fetchTile {
            return fetchTile
        }
        let created = makeFetchTile()
        fetchTile = created
        return created
    }

    private func publishRegions(notify: Bool = true) {
        regions = statuses.values.sorted { $0.region.id < $1.region.id }
        if notify {
            onRegionsChanged?()
        }
    }

    #if DEBUG
    func activeDownloadTaskForTesting(regionID: String) -> Task<Void, Never>? {
        downloadTasks[regionID]
    }
    #endif
}
