// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

final class DefaultTileLoadPipeline: TileLoadPipeline {
    // nil when the prepared-tile cache is disabled; the pipeline then always parses
    // from raw bytes and never persists the parsed result.
    private let preparedTileDiskCaching: PreparedTileDiskCaching?
    private let tileDownloader: TileDownloader
    private weak var tileRenderStore: TileRenderStore?

    init(tileRenderStore: TileRenderStore,
         config: ImmersiveMapSettings,
         preparedTileCacheIdentity: PreparedTileCacheIdentity) {
        self.preparedTileDiskCaching = config.tiles.cache.preparedTileCacheEnabled
            ? PreparedTileDiskCaching(config: config, cacheIdentity: preparedTileCacheIdentity)
            : nil
        self.tileDownloader = TileDownloader(config: config)
        self.tileRenderStore = tileRenderStore
    }

    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileCPU? {
        await preparedTileDiskCaching?.requestPreparedDiskCached(tile: tile, matchingETag: matchingETag)
    }

    func download(tile: Tile) async -> TileDownloader.DownloadResult {
        await tileDownloader.downloadResult(tile: tile)
    }

    func savePreparedOnDisk(tile: Tile, preparedTile: PreparedTileCPU, sourceETag: String?) {
        preparedTileDiskCaching?.saveOnDisk(tile: tile, preparedTile: preparedTile, sourceETag: sourceETag)
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

    func materialize(preparedTile: PreparedTileCPU) async -> Bool {
        guard let tileRenderStore else {
            return false
        }
        return await tileRenderStore.materializePreparedTile(preparedTile)
    }

    func parse(tile: Tile, data: Data) async -> Bool {
        guard let result = await prepare(tile: tile, data: data) else {
            return false
        }
        return await materialize(preparedTile: result.preparedTile)
    }
}
