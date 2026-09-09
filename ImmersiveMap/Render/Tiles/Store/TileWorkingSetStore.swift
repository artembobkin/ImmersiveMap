// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// The tiles resident in GPU memory. Membership is the frame's demanded set
/// (the coverage targets, the stand-in ancestors chosen for the loading
/// ones, and the horizon backdrop), the pinned world cover below, and a
/// short retention: the last `retentionLimit` tiles the demand stopped
/// naming, oldest out first. The retention is what makes the placement a
/// function of the present: a tile the camera left a moment ago is still
/// here to stand in or to come straight back, and nothing has to be carried
/// from one frame's placement to the next. Beyond it the prepared disk
/// cache is the layer a revisited place comes back from.
///
/// Command buffers retain every resource they bind, so releasing an entry
/// never frees a buffer the GPU still reads.
final class TileWorkingSetStore {
    /// How many tiles released by the demand stay resident, oldest out
    /// first. Fifteen is a frame's worth of coverage: a turn of the camera
    /// that swaps the far field can come back without touching the disk.
    static let retentionLimit = 15

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
    /// The tiles the demand stopped naming, oldest first, still resident.
    private var retained: [Tile] = []
    /// Where each resident tile last stood in the demand's priority order
    /// (nearest the camera first): what decides which of the tiles leaving
    /// in one frame the retention keeps.
    private var lastPriorityByTile: [Tile: Int] = [:]
    private var mutationVersion: UInt64 = 0
    private var residentBytes = 0

    /// The retention's size, `retentionLimit` unless a test asks otherwise.
    let retentionLimit: Int

    init(tileTraceRecorder: TileTraceRecorder, retentionLimit: Int = TileWorkingSetStore.retentionLimit) {
        self.retentionLimit = max(0, retentionLimit)
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

    /// The frame's demanded set, nearest the camera first. A resident tile
    /// above the pinned world cover that the set does not name moves into
    /// the retention; a retained tile the set names again leaves it; and
    /// the retention's oldest entries beyond `retentionLimit` are released
    /// here, synchronously: this is the one release path in the steady
    /// state. Tiles leaving in the same frame queue farthest first, by the
    /// priority they last had, so a level change that releases more than
    /// the retention holds keeps the tiles nearest the camera.
    func updateDemandedTiles(_ orderedTiles: [Tile]) {
        let tiles = Set(orderedTiles)
        var releasedTiles: [Tile] = []
        stateLock.lock()
        demandedTiles = tiles
        for (priority, tile) in orderedTiles.enumerated() {
            lastPriorityByTile[tile] = priority
        }
        retained.removeAll { tiles.contains($0) || entries[$0] == nil }
        var retainedSet = Set(retained)
        let leavers = entries.keys
            .filter { $0.z > Self.pinnedWorldCoverMaxZoomLevel && tiles.contains($0) == false && retainedSet.contains($0) == false }
            .sorted { lhs, rhs in
                let left = lastPriorityByTile[lhs] ?? Int.max
                let right = lastPriorityByTile[rhs] ?? Int.max
                if left != right {
                    return left > right
                }
                return Self.isOrderedBefore(lhs, rhs)
            }
        for key in leavers {
            retained.append(key)
            retainedSet.insert(key)
        }
        while retained.count > retentionLimit {
            let key = retained.removeFirst()
            releaseLocked(key)
            releasedTiles.append(key)
        }
        let snapshot = (count: entries.count, bytes: residentBytes)
        stateLock.unlock()

        for key in releasedTiles {
            tileTraceRecorder.record(.tileStoreRelease(key,
                                                       reason: "retention_full",
                                                       residentCount: snapshot.count,
                                                       residentBytes: snapshot.bytes))
        }
    }

    /// Every resident tile, the retention included: what the placement
    /// planner builds a frame from.
    func residentTiles() -> [Tile: MetalTile] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return entries.mapValues(\.metalTile)
    }

    /// Diagnostics and tests: the tiles in the retention, oldest first.
    var retainedTiles: [Tile] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retained
    }

    private static func isOrderedBefore(_ lhs: Tile, _ rhs: Tile) -> Bool {
        if lhs.z != rhs.z { return lhs.z > rhs.z }
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        return lhs.y < rhs.y
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

    /// Residency without the lookup trace: the demand planner asks this per
    /// target per frame, and a trace event for each would drown the log.
    func contains(_ key: Tile) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return entries[key] != nil
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
    /// demanded set, the retention and the pinned world cover included, so
    /// the map on screen stays intact while the off-screen residue is
    /// handed back. The cover warms up again lazily from the prepared disk
    /// cache.
    func releaseUndemandedTiles() {
        var releasedTiles: [Tile] = []
        stateLock.lock()
        for key in Array(entries.keys) where demandedTiles.contains(key) == false {
            releaseLocked(key)
            releasedTiles.append(key)
        }
        retained.removeAll()
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
        retained.removeAll()
        lastPriorityByTile.removeAll()
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
        lastPriorityByTile.removeValue(forKey: key)
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
