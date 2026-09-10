// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// The tiles resident in GPU memory. Membership is a function of the
/// present, nothing is carried from one frame to the next: the frame's
/// demanded set (the coverage targets and the horizon backdrop), the
/// pinned world cover below, and the tiles that stand in for a demanded
/// target that has not arrived yet. A tile the demand stopped naming
/// stays while it is such a stand-in and leaves the moment it is not:
///
/// - a descendant of a loading target, at any depth: a zoom-out keeps the
///   detailed tiles the camera was just looking at until their ancestor
///   lands on top of them, however far the zoom has run ahead of the loads;
/// - the finest resident ancestor of a loading target: a zoom-in keeps the
///   parent until every child that replaces it has landed.
///
/// Those are exactly the tiles `TilePlacementPlanner` would draw for the
/// target, so nothing is kept that the frame cannot show, and nothing the
/// frame shows is released under it, not even by a memory warning. There
/// is no retention beyond that: a tile the camera left comes back from
/// the prepared disk cache.
///
/// Command buffers retain every resource they bind, so releasing an entry
/// never frees a buffer the GPU still reads.
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
    /// Scratch for `updateDemandedTiles`, kept across calls so the steady
    /// state allocates nothing: the ancestors kept this pass, and the
    /// tiles to release.
    private var keptAncestors: Set<Tile> = []
    private var releaseScratch: [Tile] = []

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
    /// cover that the set does not name and that stands in for none of the
    /// set's loading tiles is released here, synchronously: this is the one
    /// release path in the steady state. Decided from the set and the
    /// residency alone; the order carries no meaning here.
    func updateDemandedTiles(_ orderedTiles: [Tile]) {
        stateLock.lock()
        demandedTiles.removeAll(keepingCapacity: true)
        for tile in orderedTiles {
            demandedTiles.insert(tile)
        }
        collectReleasableLocked(pinnedCoverToo: false)
        for tile in releaseScratch {
            releaseLocked(tile)
        }
        let snapshot = (count: entries.count, bytes: residentBytes)
        stateLock.unlock()

        for tile in releaseScratch {
            tileTraceRecorder.record(.tileStoreRelease(tile,
                                                       reason: "not_demanded",
                                                       residentCount: snapshot.count,
                                                       residentBytes: snapshot.bytes))
        }
    }

    /// Fills `releaseScratch` with the resident tiles the frame has no use
    /// for: not demanded, and standing in for no loading tile. The pinned
    /// world cover is spared unless asked for, and even then a cover tile
    /// standing in (the sphere draws the cover under a loading target)
    /// stays. Called under the lock.
    private func collectReleasableLocked(pinnedCoverToo: Bool) {
        // The finest resident ancestor of every loading target is what the
        // placement draws under it until it lands. The walk stops above the
        // cover while the cover is not in question: it is never released
        // then, so marking it would be work for nothing.
        let ancestorFloorZoom = pinnedCoverToo ? 0 : Self.pinnedWorldCoverMaxZoomLevel + 1
        keptAncestors.removeAll(keepingCapacity: true)
        for target in demandedTiles where entries[target] == nil && target.z > ancestorFloorZoom {
            var ancestor = target
            while ancestor.z > ancestorFloorZoom {
                guard let parent = ancestor.findParentTile(atZoom: ancestor.z - 1) else { break }
                ancestor = parent
                if entries[ancestor] != nil {
                    keptAncestors.insert(ancestor)
                    break
                }
            }
        }

        releaseScratch.removeAll(keepingCapacity: true)
        for tile in entries.keys where demandedTiles.contains(tile) == false {
            if tile.z <= Self.pinnedWorldCoverMaxZoomLevel, pinnedCoverToo == false {
                continue
            }
            if keptAncestors.contains(tile) || standsInBelowALoadingTarget(tile) {
                continue
            }
            releaseScratch.append(tile)
        }
    }

    /// Whether a resident tile is a descendant, at any depth, of a demanded
    /// tile that is not resident: what the placement draws in the target's
    /// place until it lands. Called under the lock.
    private func standsInBelowALoadingTarget(_ tile: Tile) -> Bool {
        var ancestor = tile
        while ancestor.z > 0, let parent = ancestor.findParentTile(atZoom: ancestor.z - 1) {
            ancestor = parent
            if demandedTiles.contains(ancestor) {
                return entries[ancestor] == nil
            }
        }
        return false
    }

    /// Every resident tile, the stand-ins included: what the placement
    /// planner builds a frame from.
    func residentTiles() -> [Tile: MetalTile] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return entries.mapValues(\.metalTile)
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

    /// Residency without the lookup trace, for the per-frame checks that
    /// would drown the log with a trace event each.
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

    /// The memory-warning response: hands back the pinned world cover
    /// outside the current demand, which is the one thing the steady state
    /// keeps beyond the frame's needs. What the frame draws, the demanded
    /// tiles and the stand-ins under the loading ones, stays: a warning must
    /// not blank the screen it arrives on. The cover warms up again lazily
    /// from the prepared disk cache.
    func releaseUndemandedTiles() {
        stateLock.lock()
        collectReleasableLocked(pinnedCoverToo: true)
        for key in releaseScratch {
            releaseLocked(key)
        }
        if releaseScratch.isEmpty == false {
            mutationVersion &+= 1
        }
        let snapshot = (count: entries.count, bytes: residentBytes)
        stateLock.unlock()

        for key in releaseScratch {
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
