// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// A rasterized tile's identity: the tile and the texels a side it was
/// rendered at. A tile's content is fixed for its life in the working set,
/// so nothing else keys the picture.
struct TileRasterKey: Hashable {
    let tile: Tile
    let resolution: Int
    /// The ground families the picture holds (`RasterZone.pictureGroups`):
    /// each set is a different picture.
    var groups: GroundLayerGroups = .all
    /// The building fills' footprint fade the picture was drawn with, whole
    /// square pixels: a picture bakes the fade in.
    var footprintGoneAreaPx: Int = 0
    var footprintOpaqueAreaPx: Int = 0
}

/// The rasterized tiles' pictures (`TileRasterizer`), kept for as long as
/// a frame keeps asking for them: a picture no frame touched for
/// `retentionFrames` frames is released, and so is everything on eviction.
/// Main thread only, like the frame engine.
final class TileRasterStore {
    /// Frames a picture outlives its last use: a rotation that swings a
    /// tile out of view and back does not render it twice.
    static let retentionFrames: UInt64 = 120

    private struct Entry {
        let texture: MTLTexture
        var lastUsedFrame: UInt64
    }

    private var entries: [TileRasterKey: Entry] = [:]

    var count: Int { entries.count }

    /// The picture, marked used by `frameIndex`. Nil when it has not been
    /// rendered.
    func texture(for key: TileRasterKey, frameIndex: UInt64) -> MTLTexture? {
        guard var entry = entries[key] else { return nil }
        entry.lastUsedFrame = frameIndex
        entries[key] = entry
        return entry.texture
    }

    func contains(_ key: TileRasterKey) -> Bool {
        entries[key] != nil
    }

    func insert(_ texture: MTLTexture, for key: TileRasterKey, frameIndex: UInt64) {
        entries[key] = Entry(texture: texture, lastUsedFrame: frameIndex)
    }

    /// Releases every picture unused since `retentionFrames` before
    /// `frameIndex`.
    func releaseStale(frameIndex: UInt64) {
        guard frameIndex > Self.retentionFrames else { return }
        let cutoff = frameIndex - Self.retentionFrames
        entries = entries.filter { $0.value.lastUsedFrame >= cutoff }
    }

    func removeAll() {
        entries.removeAll()
    }
}
