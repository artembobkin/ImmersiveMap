// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A prepared tile read back from the disk cache in arena-image form,
/// together with the raw-tile ETag it was parsed from. `sourceETag` is nil
/// when the server sent no ETag at save time. The disk stage ignores it; the
/// CPU stage's ETag-matched lookup uses it to reuse an entry another engine
/// saved from the exact bytes just downloaded.
struct PreparedTileDiskCacheHit {
    let image: PreparedTileArenaImage
    let sourceETag: String?
}

/// Outcome of materializing a tile into GPU state. The distinction matters
/// for cleanup: an unreadable image is corrupt on disk and must be removed so
/// the tile re-parses, while an allocation or store failure is a transient
/// condition and any disk entry stays. Materializing a freshly parsed tile
/// can never be `imageUnreadable`; the parse path reports transient failures
/// only.
enum PreparedTileMaterializeOutcome {
    case materialized
    case allocationOrStoreFailed
    case imageUnreadable
}

protocol TileLoadPipeline {
    /// False when no prepared disk cache exists (the setting is off, or the
    /// pipeline owns none); the loader then skips the disk stage instead of
    /// running a guaranteed miss for every tile.
    var hasPreparedDiskCache: Bool { get }
    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileDiskCacheHit?
    func download(tile: Tile) async -> TileDownloader.DownloadResult
    /// `plan` is the arena plan of the same parse when the caller already
    /// built one for the materialize, so the layout work runs once.
    func savePreparedOnDisk(tile: Tile,
                            preparedTile: PreparedTileCPU,
                            plan: TileArenaImagePlan?,
                            sourceETag: String?) async
    func removePreparedFromDisk(tile: Tile)
    func prepare(tile: Tile, data: Data) async -> PreparedTileLoadResult?
    func materialize(preparedTile: PreparedTileCPU,
                     plan: TileArenaImagePlan?) async -> PreparedTileMaterializeOutcome
    /// Materializes a disk-cached arena image (blob copy or MTLIO load plus
    /// span-table reconstruction) instead of a parsed tile.
    func materialize(image: PreparedTileArenaImage) async -> PreparedTileMaterializeOutcome
}
