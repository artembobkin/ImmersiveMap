// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

protocol TileLoadPipeline {
    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileCPU?
    func download(tile: Tile) async -> TileDownloader.DownloadResult
    func savePreparedOnDisk(tile: Tile, preparedTile: PreparedTileCPU, sourceETag: String?)
    func removePreparedFromDisk(tile: Tile)
    func prepare(tile: Tile, data: Data) async -> PreparedTileLoadResult?
    func materialize(preparedTile: PreparedTileCPU) async -> Bool
    func parse(tile: Tile, data: Data) async -> Bool
}
