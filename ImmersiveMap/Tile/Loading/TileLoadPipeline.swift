// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A prepared tile read back from the disk cache in arena-image form,
/// together with the raw-tile ETag it was parsed from. `sourceETag` is nil
/// when the server sent no ETag at save time; the loader then cannot
/// revalidate the entry by comparison.
struct PreparedTileDiskCacheHit {
    let image: PreparedTileArenaImage
    let sourceETag: String?
}

/// Outcome of materializing a disk-cached arena image. The distinction
/// matters for cleanup: an unreadable image is corrupt on disk and must be
/// removed so the tile re-parses, while an allocation failure is a transient
/// memory condition and the entry stays.
enum PreparedTileImageMaterializeOutcome {
    case materialized
    case allocationOrStoreFailed
    case imageUnreadable
}

protocol TileLoadPipeline {
    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileDiskCacheHit?
    func download(tile: Tile) async -> TileDownloader.DownloadResult
    func savePreparedOnDisk(tile: Tile, preparedTile: PreparedTileCPU, sourceETag: String?) async
    func removePreparedFromDisk(tile: Tile)
    func prepare(tile: Tile, data: Data) async -> PreparedTileLoadResult?
    /// `awaitingRevalidation` marks a disk-first serve whose ETag has not been
    /// checked against the network yet; the render store keeps such tiles
    /// requestable (see `requestTiles`) until a later materialize or
    /// `markRevalidated` resolves them.
    func materialize(preparedTile: PreparedTileCPU, awaitingRevalidation: Bool) async -> Bool
    /// Materializes a disk-cached arena image (blob copy or MTLIO load plus
    /// span-table reconstruction) instead of a parsed tile.
    func materialize(image: PreparedTileArenaImage,
                     awaitingRevalidation: Bool) async -> PreparedTileImageMaterializeOutcome
    /// Resolves a disk-first serve: the download confirmed the served content
    /// (ETag match) or the loader knowingly accepted it (offline fallback).
    func markRevalidated(tile: Tile) async
    func parse(tile: Tile, data: Data) async -> Bool
}
