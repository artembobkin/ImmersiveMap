// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

class MemoryMetalTileCache {
    /// Low-zoom world coverage is pinned lazily: once materialized,
    /// tiles with z <= this level are not evicted by regular LRU pressure -
    /// the far zone of a tilted camera stays resident (the whole world at
    /// z0-3 is at most 85 generalized tiles). The eviction budget
    /// is extended by their cost so pinning doesn't evict nearby tiles.
    /// Invisible pinned tiles don't survive a memory warning: they warm up again.
    static let pinnedWorldCoverMaxZoomLevel = 3

    /// Frames a tile must sit outside the demanded set and the retained
    /// placements before its buffers go volatile: covers every in-flight GPU
    /// frame that may still read them, plus one for the frame being encoded.
    static let volatileDelayFrames = UInt64(InFlightFramePool.inFlightFramesCount + 1)

    private var cache: LRUMemoryCache<Tile, MetalTile>
    private let costLimit: Int
    private let stateLock = NSLock()
    private let tileTraceRecorder: TileTraceRecorder
    // Tiles of the current demanded set: not evicted on insert or on trim,
    // otherwise with a working set larger than the limit the cache ping-pongs visible tiles.
    private var protectedTiles: Set<Tile> = []
    private var pinnedTiles: Set<Tile> = []
    private var pinnedCost: Int = 0
    private var mutationVersion: UInt64 = 0
    // Purgeable bookkeeping: buffers of tiles that are cached but neither
    // demanded, pinned, nor retained by a placement are offered to the OS as
    // volatile, so memory pressure reclaims warm-cache tiles system-wide
    // before jetsam ever looks at the process. A reclaimed tile is detected
    // on the next lookup and drops out as a plain cache miss.
    private var volatileTiles: Set<Tile> = []
    private var lastActiveFrame: [Tile: UInt64] = [:]

    init(maxCacheSizeInBytes: Int, tileTraceRecorder: TileTraceRecorder) {
        self.costLimit = maxCacheSizeInBytes
        self.tileTraceRecorder = tileTraceRecorder
        self.cache = LRUMemoryCache(costLimit: maxCacheSizeInBytes)
    }

    // Changes on every content mutation (insert/eviction/clear) -
    // the key for dirty-gates that depend on tile readiness.
    var contentVersion: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mutationVersion
    }

    /// Test hook: the number of activity stamps currently tracked. Must stay
    /// bounded by the cache contents; a stamp for a tile that never
    /// materialized would otherwise leak for the process lifetime.
    var trackedActivityStampCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastActiveFrame.count
    }

    func updateProtectedTiles(_ tiles: Set<Tile>) {
        let result: (evicted: [LRUMemoryCache<Tile, MetalTile>.Entry], totalCost: Int, count: Int)
        stateLock.lock()
        protectedTiles = tiles
        // The overshoot from protecting demanded tiles is eliminated as soon as the set
        // shrinks: otherwise the cache would hold the limit excess until the next insert
        // or memory warning. In the normal case (totalCost <= limit) - a no-op.
        let effectiveCostLimit = costLimit + pinnedCost
        if cache.totalCost > effectiveCostLimit {
            let evicted = cache.trim(toCost: effectiveCostLimit,
                                     protectedKeys: protectedTiles.union(pinnedTiles))
            if evicted.isEmpty == false {
                mutationVersion &+= 1
                forgetPurgeableBookkeepingLocked(for: evicted)
            }
            result = (evicted, cache.totalCost, cache.count)
        } else {
            result = ([], cache.totalCost, cache.count)
        }
        stateLock.unlock()

        for evictedEntry in result.evicted {
            tileTraceRecorder.record(.tileMemoryCacheEvict(evictedEntry.key,
                                                           cost: evictedEntry.cost,
                                                           trackedCost: result.totalCost,
                                                           trackedCount: result.count,
                                                           costLimit: costLimit))
        }
    }

    /// The set of tiles actually referenced by the current placements
    /// (retained substitutes included), stamped with the frame index. Cached
    /// tiles outside the demanded, pinned, and active sets go volatile once
    /// the in-flight window has passed; the pinned world cover keeps its
    /// residency promise and is never offered to the OS.
    func recordActiveTiles(_ activeTiles: Set<Tile>, frameIndex: UInt64) {
        var markedVolatile: [Tile] = []
        stateLock.lock()
        // Stamp only tiles that live in the cache: the demanded set contains
        // tiles that may never materialize (404s, parse failures, requests
        // dropped when the camera moves on) and placements can retain a tile
        // past its eviction. Guarding on membership keeps lastActiveFrame a
        // subset of the cache keys, so the eviction paths bound its growth.
        for tile in activeTiles where cache.cost(forKey: tile) != nil {
            lastActiveFrame[tile] = frameIndex
        }
        for tile in protectedTiles where cache.cost(forKey: tile) != nil {
            lastActiveFrame[tile] = frameIndex
        }
        for key in cache.keys {
            guard volatileTiles.contains(key) == false,
                  protectedTiles.contains(key) == false,
                  pinnedTiles.contains(key) == false,
                  activeTiles.contains(key) == false else {
                continue
            }
            let lastActive = lastActiveFrame[key] ?? 0
            guard frameIndex >= lastActive &+ Self.volatileDelayFrames,
                  let metalTile = cache.peekValue(forKey: key) else {
                continue
            }
            metalTile.tileBuffers.markVolatile()
            volatileTiles.insert(key)
            markedVolatile.append(key)
        }
        stateLock.unlock()

        for key in markedVolatile {
            tileTraceRecorder.record(.event("tile_memory_cache_volatile",
                                            fields: ["tile": .string("\(key.z)/\(key.x)/\(key.y)")]))
        }
    }

    func setTileData(tile: MetalTile, forKey key: Tile) {
        let estimatedCost = estimateTileByteSize(tile)
        let mutation = setTile(tile, forKey: key, cost: estimatedCost)
        tileTraceRecorder.record(.tileMemoryCacheSet(key,
                                                     cost: estimatedCost,
                                                     replacedCost: mutation.replacedCost,
                                                     trackedCost: mutation.totalCost,
                                                     trackedCount: mutation.count,
                                                     costLimit: costLimit))
        for evictedEntry in mutation.evictedEntries {
            tileTraceRecorder.record(.tileMemoryCacheEvict(evictedEntry.key,
                                                           cost: evictedEntry.cost,
                                                           trackedCost: mutation.totalCost,
                                                           trackedCount: mutation.count,
                                                           costLimit: costLimit))
        }
    }
    
    func getTile(forKey key: Tile) -> MetalTile? {
        let snapshot = getTileAndSnapshot(forKey: key)
        tileTraceRecorder.record(.tileMemoryCacheGet(key,
                                                     hit: snapshot.tile != nil,
                                                     knownCost: snapshot.knownCost,
                                                     trackedCost: snapshot.totalCost,
                                                     trackedCount: snapshot.count,
                                                     costLimit: costLimit))
        if snapshot.wasReclaimed {
            tileTraceRecorder.record(.event("tile_memory_cache_reclaimed",
                                            fields: ["tile": .string("\(key.z)/\(key.x)/\(key.y)")]))
        }
        return snapshot.tile
    }

    func removeAll() {
        let snapshot = removeAllTiles()
        tileTraceRecorder.record(.event("tile_memory_cache_remove_all",
                                        fields: [
                                            "removedCost": .int(snapshot.totalCost),
                                            "removedCount": .int(snapshot.count),
                                            "costLimit": .int(costLimit)
                                        ]))
    }

    // Resets the cache down to a fraction of the limit, keeping protected (visible) tiles -
    // a soft memory warning response instead of a full clear and an empty map.
    // Pinned tiles are not protected here: under memory pressure the world coverage
    // is released and later warms up again lazily.
    func trim(toFractionOfLimit fraction: Double) {
        let targetCost = Int(Double(costLimit) * max(0.0, min(1.0, fraction)))
        let result: (evicted: [LRUMemoryCache<Tile, MetalTile>.Entry], totalCost: Int, count: Int)
        stateLock.lock()
        let evicted = cache.trim(toCost: targetCost, protectedKeys: protectedTiles)
        for evictedEntry in evicted where pinnedTiles.contains(evictedEntry.key) {
            pinnedTiles.remove(evictedEntry.key)
            pinnedCost = max(0, pinnedCost - evictedEntry.cost)
        }
        forgetPurgeableBookkeepingLocked(for: evicted)
        if evicted.isEmpty == false {
            mutationVersion &+= 1
        }
        result = (evicted, cache.totalCost, cache.count)
        stateLock.unlock()

        for evictedEntry in result.evicted {
            tileTraceRecorder.record(.tileMemoryCacheEvict(evictedEntry.key,
                                                           cost: evictedEntry.cost,
                                                           trackedCost: result.totalCost,
                                                           trackedCount: result.count,
                                                           costLimit: costLimit))
        }
    }

    private func setTile(_ tile: MetalTile,
                         forKey key: Tile,
                         cost: Int) -> (replacedCost: Int?,
                                        evictedEntries: [LRUMemoryCache<Tile, MetalTile>.Entry],
                                        totalCost: Int,
                                        count: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let replacedCost = cache.cost(forKey: key)
        if key.z <= Self.pinnedWorldCoverMaxZoomLevel {
            pinnedTiles.insert(key)
            pinnedCost = max(0, pinnedCost + max(0, cost) - (replacedCost ?? 0))
        }
        let evictedEntries = cache.setValue(tile,
                                            forKey: key,
                                            cost: cost,
                                            protectedKeys: protectedTiles.union(pinnedTiles),
                                            evictionCostLimit: costLimit + pinnedCost) ?? []
        // A replaced value keeps the key: the fresh tile must not inherit the
        // predecessor's volatile mark.
        volatileTiles.remove(key)
        forgetPurgeableBookkeepingLocked(for: evictedEntries)
        mutationVersion &+= 1
        return (replacedCost, evictedEntries, cache.totalCost, cache.count)
    }

    private func forgetPurgeableBookkeepingLocked(for evicted: [LRUMemoryCache<Tile, MetalTile>.Entry]) {
        for entry in evicted {
            volatileTiles.remove(entry.key)
            lastActiveFrame.removeValue(forKey: entry.key)
        }
    }

    private func getTileAndSnapshot(forKey key: Tile) -> (tile: MetalTile?,
                                                          knownCost: Int?,
                                                          totalCost: Int,
                                                          count: Int,
                                                          wasReclaimed: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let tile = cache.value(forKey: key) else {
            return (nil, nil, cache.totalCost, cache.count, false)
        }
        if volatileTiles.remove(key) != nil,
           tile.tileBuffers.restoreFromVolatile() == false {
            // The OS reclaimed the volatile buffers: the tile is gone in all
            // but name, so it leaves the cache as a plain miss and reloads
            // through the normal demand path.
            if let removed = cache.removeValue(forKey: key) {
                if pinnedTiles.remove(key) != nil {
                    pinnedCost = max(0, pinnedCost - removed.cost)
                }
                lastActiveFrame.removeValue(forKey: key)
                mutationVersion &+= 1
            }
            return (nil, nil, cache.totalCost, cache.count, true)
        }
        return (tile, cache.cost(forKey: key), cache.totalCost, cache.count, false)
    }

    private func removeAllTiles() -> (totalCost: Int, count: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let snapshot = (cache.totalCost, cache.count)
        _ = cache.removeAll()
        pinnedTiles = []
        pinnedCost = 0
        volatileTiles = []
        lastActiveFrame = [:]
        mutationVersion &+= 1
        return snapshot
    }
    
    private func estimateTileByteSize(_ tile: MetalTile) -> Int {
        tile.tileBuffers.backingBuffer.map(Self.byteSize(of:)) ?? 0
    }

    /// What one buffer costs the cache.
    ///
    /// `allocatedSize` is the figure to use where it is available: it counts
    /// the padding the driver added, which the requested length does not. The
    /// iOS Simulator's GPU reports 0 for it, for every buffer at every size.
    /// Taken at face value that puts every tile at cost 0, and a budget whose
    /// total never exceeds the limit never evicts: the tile cache would grow
    /// without bound for the whole run. The requested length is the honest
    /// lower bound to fall back on.
    private static func byteSize(of buffer: MTLBuffer) -> Int {
        buffer.allocatedSize > 0 ? buffer.allocatedSize : buffer.length
    }
}
