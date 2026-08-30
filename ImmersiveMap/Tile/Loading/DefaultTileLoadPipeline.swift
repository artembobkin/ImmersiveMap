// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

final class DefaultTileLoadPipeline: TileLoadPipeline {
    // nil when the prepared-tile cache is disabled; the pipeline then always parses
    // from raw bytes and never persists the parsed result.
    private let preparedTileDiskCaching: PreparedTileDiskCaching?
    // nil in offline-only mode: the pipeline then owns no network transport at
    // all, which also keeps the TileJSON discovery request from ever firing.
    private let tileDownloader: TileDownloader?
    // nil when offline regions are disabled.
    private let offlineTileStore: OfflineTileStore?
    private let offlineMode: ImmersiveMapSettings.TileSettings.OfflineSettings.Mode
    private weak var tileRenderStore: TileRenderStore?

    convenience init(tileRenderStore: TileRenderStore,
                     config: ImmersiveMapSettings,
                     preparedTileCacheIdentity: PreparedTileCacheIdentity,
                     geometryTransport: any PreparedTileGeometryTransporting) {
        let offlineMode = config.tiles.offline.mode
        self.init(tileRenderStore: tileRenderStore,
                  preparedTileDiskCaching: config.tiles.cache.preparedTileCacheEnabled
                      ? PreparedTileDiskCaching(config: config,
                                                cacheIdentity: preparedTileCacheIdentity,
                                                geometryTransport: geometryTransport)
                      : nil,
                  tileDownloader: offlineMode == .offlineOnly ? nil : TileDownloader(config: config),
                  offlineTileStore: offlineMode == .disabled ? nil : OfflineTileStore(network: config.tiles.network),
                  offlineMode: offlineMode)
    }

    init(tileRenderStore: TileRenderStore?,
         preparedTileDiskCaching: PreparedTileDiskCaching?,
         tileDownloader: TileDownloader?,
         offlineTileStore: OfflineTileStore?,
         offlineMode: ImmersiveMapSettings.TileSettings.OfflineSettings.Mode) {
        self.preparedTileDiskCaching = preparedTileDiskCaching
        self.tileDownloader = tileDownloader
        self.offlineTileStore = offlineTileStore
        self.offlineMode = offlineMode
        self.tileRenderStore = tileRenderStore
    }

    var hasPreparedDiskCache: Bool {
        preparedTileDiskCaching != nil
    }

    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileDiskCacheHit? {
        await preparedTileDiskCaching?.requestPreparedDiskCached(tile: tile, matchingETag: matchingETag)
    }

    func download(tile: Tile) async -> TileDownloader.DownloadResult {
        switch offlineMode {
        case .disabled:
            return await networkResult(tile: tile)
        case .offlineOnly:
            // A miss reports `.network`, whose short retry backoff makes the
            // tile recheck the store while a region download is filling it.
            return offlineTileStore?.downloadResult(for: tile) ?? .failure(.network)
        case .automatic:
            let result = await networkResult(tile: tile)
            if case .failure = result,
               let offlineResult = offlineTileStore?.downloadResult(for: tile) {
                return offlineResult
            }
            return result
        }
    }

    private func networkResult(tile: Tile) async -> TileDownloader.DownloadResult {
        guard let tileDownloader else {
            return .failure(.network)
        }
        return await tileDownloader.downloadResult(tile: tile)
    }

    func savePreparedOnDisk(tile: Tile,
                            preparedTile: PreparedTileCPU,
                            plan: TileArenaImagePlan?,
                            sourceETag: String?) async {
        await preparedTileDiskCaching?.saveOnDisk(tile: tile,
                                                  preparedTile: preparedTile,
                                                  plan: plan,
                                                  sourceETag: sourceETag)
    }

    func removePreparedFromDisk(tile: Tile) {
        preparedTileDiskCaching?.removeFromDisk(tile: tile)
    }

    func prepare(tile: Tile, data: Data) async -> PreparedTileLoadResult? {
        guard let tileRenderStore else {
            return nil
        }
        return await tileRenderStore.prepareTile(tile: tile, data: data)
    }

    func materialize(preparedTile: PreparedTileCPU,
                     plan: TileArenaImagePlan?) async -> PreparedTileMaterializeOutcome {
        guard let tileRenderStore else {
            return .allocationOrStoreFailed
        }
        let isMaterialized = await tileRenderStore.materializePreparedTile(preparedTile,
                                                                           plan: plan)
        return isMaterialized ? .materialized : .allocationOrStoreFailed
    }

    func materialize(image: PreparedTileArenaImage) async -> PreparedTileMaterializeOutcome {
        guard let tileRenderStore else {
            return .allocationOrStoreFailed
        }
        return await tileRenderStore.materializeArenaImage(image)
    }
}
