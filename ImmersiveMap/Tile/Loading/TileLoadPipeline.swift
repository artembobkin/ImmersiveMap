// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A prepared tile read back from the disk cache, together with the raw-tile
/// ETag it was parsed from. `sourceETag` is nil when the server sent no ETag
/// at save time; the loader then cannot revalidate the entry by comparison.
struct PreparedTileDiskCacheHit {
    let preparedTile: PreparedTileCPU
    let sourceETag: String?
}

protocol TileLoadPipeline {
    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileDiskCacheHit?
    func download(tile: Tile) async -> TileDownloader.DownloadResult
    func savePreparedOnDisk(tile: Tile, preparedTile: PreparedTileCPU, sourceETag: String?) async
    func removePreparedFromDisk(tile: Tile)
    func prepare(tile: Tile, data: Data) async -> PreparedTileLoadResult?
    /// `awaitingRevalidation` marks a disk-first serve whose ETag has not been
    /// checked against the network yet; the render store keeps such tiles
    /// requestable until a later materialize or `markRevalidated` resolves them.
    func materialize(preparedTile: PreparedTileCPU, awaitingRevalidation: Bool) async -> Bool
    /// Resolves a disk-first serve: the download confirmed the served content
    /// (ETag match) or the loader knowingly accepted it (offline fallback).
    func markRevalidated(tile: Tile) async
    func parse(tile: Tile, data: Data) async -> Bool
}
