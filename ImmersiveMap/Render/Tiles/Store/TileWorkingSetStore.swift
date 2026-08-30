// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// The tiles resident in GPU memory: exactly what the frame draws, with no
/// history. Membership is the frame's demanded set (the visible tiles, their
/// fallback parents, the horizon backdrop and the shadow-caster strip) plus
/// the pinned world cover below, and every other tile is released the moment
/// the demanded set stops naming it. There is no byte budget and no LRU: the
/// prepared disk cache is the layer a revisited place comes back from.
///
/// Substitute tiles that placements retain after leaving demand survive on
/// their own strong references (`PlaceTile.metalTile`), and command buffers
/// retain every resource they bind, so releasing an entry never frees a
/// buffer the GPU still reads.
final class TileWorkingSetStore {
    /// Low-zoom world coverage is pinned lazily: once materialized, tiles
    /// with z <= this level are not released when they leave the demanded
    /// set, so the far zone of a tilted camera and the globe's back side
    /// stay resident (the whole world at z0-3 is at most 85 generalized
    /// tiles). A memory warning still drops the ones not currently demanded;
    /// they warm up again from disk.
    static let pinnedWorldCoverMaxZoomLevel = 3

    private struct Entry {
        let metalTile: MetalTile
        let byteCount: Int
    }

    private let stateLock = NSLock()
    private let tileTraceRecorder: TileTraceRecorder
    private var entries: [Tile: Entry] = [:]
    private var demandedTiles: Set<Tile> = []
    private var mutationVersion: UInt64 = 0
    private var residentBytes = 0

    init(tileTraceRecorder: TileTraceRecorder) {
        self.tileTraceRecorder = tileTraceRecorder
    }

    /// Changes on every mutation that can affect a demanded tile's readiness:
    /// insert, memory-warning release, full clear. Together with
    /// coverageVersion it forms the demand pipeline's dirty-gate key.
    /// Releases performed by `updateDemandedTiles` do not bump it: they touch
    /// only tiles the demand pass that triggered them already stopped asking
    /// about, so re-running that pass would change nothing.
    var contentVersion: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mutationVersion
    }

    /// Diagnostics: how many tiles are resident right now.
    var residentTileCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return entries.count
    }

    /// Diagnostics: what the resident tiles' backing buffers hold in bytes.
    var residentByteCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return residentBytes
    }

    /// The frame's demanded set. Every resident tile above the pinned world
    /// cover that the set does not name is released here, synchronously:
    /// this is the one release path in the steady state.
    func updateDemandedTiles(_ tiles: Set<Tile>) {
        var releasedTiles: [Tile] = []
        stateLock.lock()
        demandedTiles = tiles
        for key in Array(entries.keys)
            where key.z > Self.pinnedWorldCoverMaxZoomLevel && tiles.contains(key) == false {
            releaseLocked(key)
            releasedTiles.append(key)
        }
        let snapshot = (count: entries.count, bytes: residentBytes)
        stateLock.unlock()

        for key in releasedTiles {
            tileTraceRecorder.record(.tileStoreRelease(key,
                                                       reason: "left_demand",
                                                       residentCount: snapshot.count,
                                                       residentBytes: snapshot.bytes))
        }
    }

    /// Always stores, a key outside the demanded set included: the loader
    /// finishes what it started, and a tile that lands after the camera has
    /// moved on is released by the next `updateDemandedTiles`. Offscreen
    /// harnesses rely on the same grace period when they parse tiles before
    /// any frame has demanded them.
    func insert(_ metalTile: MetalTile, forKey key: Tile) {
        let byteCount = Self.residentByteSize(of: metalTile)
        stateLock.lock()
        let replaced = entries.updateValue(Entry(metalTile: metalTile, byteCount: byteCount),
                                           forKey: key)
        residentBytes = max(0, residentBytes + byteCount - (replaced?.byteCount ?? 0))
        mutationVersion &+= 1
        let snapshot = (count: entries.count, bytes: residentBytes)
        stateLock.unlock()

        tileTraceRecorder.record(.tileStoreInsert(key,
                                                  replaced: replaced != nil,
                                                  residentCount: snapshot.count,
                                                  residentBytes: snapshot.bytes))
    }

    func tile(forKey key: Tile) -> MetalTile? {
        stateLock.lock()
        let entry = entries[key]
        let snapshot = (count: entries.count, bytes: residentBytes)
        stateLock.unlock()

        tileTraceRecorder.record(.tileStoreLookup(key,
                                                  hit: entry != nil,
                                                  residentCount: snapshot.count,
                                                  residentBytes: snapshot.bytes))
        return entry?.metalTile
    }

    /// The memory-warning response: releases everything outside the current
    /// demanded set, the pinned world cover included, so the map on screen
    /// stays intact while the off-screen residue is handed back. The cover
    /// warms up again lazily from the prepared disk cache.
    func releaseUndemandedTiles() {
        var releasedTiles: [Tile] = []
        stateLock.lock()
        for key in Array(entries.keys) where demandedTiles.contains(key) == false {
            releaseLocked(key)
            releasedTiles.append(key)
        }
        if releasedTiles.isEmpty == false {
            mutationVersion &+= 1
        }
        let snapshot = (count: entries.count, bytes: residentBytes)
        stateLock.unlock()

        for key in releasedTiles {
            tileTraceRecorder.record(.tileStoreRelease(key,
                                                       reason: "memory_warning",
                                                       residentCount: snapshot.count,
                                                       residentBytes: snapshot.bytes))
        }
    }

    func removeAll() {
        stateLock.lock()
        let snapshot = (count: entries.count, bytes: residentBytes)
        entries.removeAll()
        residentBytes = 0
        mutationVersion &+= 1
        stateLock.unlock()

        tileTraceRecorder.record(.tileStoreRemoveAll(removedCount: snapshot.count,
                                                     removedBytes: snapshot.bytes))
    }

    private func releaseLocked(_ key: Tile) {
        guard let removed = entries.removeValue(forKey: key) else {
            return
        }
        residentBytes = max(0, residentBytes - removed.byteCount)
    }

    private static func residentByteSize(of metalTile: MetalTile) -> Int {
        metalTile.tileBuffers.backingBuffer.map(byteSize(of:)) ?? 0
    }

    /// What one tile holds in GPU memory.
    ///
    /// `allocatedSize` is the figure to use where it is available: it counts
    /// the padding the driver added, which the requested length does not. The
    /// iOS Simulator's GPU reports 0 for it, for every buffer at every size,
    /// so the requested length is the honest lower bound to fall back on.
    private static func byteSize(of buffer: MTLBuffer) -> Int {
        buffer.allocatedSize > 0 ? buffer.allocatedSize : buffer.length
    }
}
