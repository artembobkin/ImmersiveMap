// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

class MemoryMetalTileCache {
    /// Low-zoom world coverage is pinned lazily: once materialized,
    /// tiles with z <= this level are not evicted by regular LRU pressure -
    /// the far zone of a tilted camera stays resident (the whole world at
    /// z0-3 is at most 85 generalized tiles). The eviction budget
    /// is extended by their cost so pinning doesn't evict nearby tiles.
    /// Invisible pinned tiles don't survive a memory warning: they warm up again.
    static let pinnedWorldCoverMaxZoomLevel = 3

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
        mutationVersion &+= 1
        return (replacedCost, evictedEntries, cache.totalCost, cache.count)
    }

    private func getTileAndSnapshot(forKey key: Tile) -> (tile: MetalTile?,
                                                          knownCost: Int?,
                                                          totalCost: Int,
                                                          count: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let tile = cache.value(forKey: key)
        return (tile, cache.cost(forKey: key), cache.totalCost, cache.count)
    }

    private func removeAllTiles() -> (totalCost: Int, count: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let snapshot = (cache.totalCost, cache.count)
        _ = cache.removeAll()
        pinnedTiles = []
        pinnedCost = 0
        mutationVersion &+= 1
        return snapshot
    }
    
    private func estimateTileByteSize(_ tile: MetalTile) -> Int {
        let tileBuffers = tile.tileBuffers
        
        let layers = [tileBuffers.ground]
            + tileBuffers.roads.drawOrderBuckets.flatMap(\.drawOrderLayers)
            + [tileBuffers.bridgeOverlay]
        // Sums are split into step-by-step +=: a chain of several `?? 0` in one
        // expression exceeds the type-checker limit on weak machines (CI).
        let geometrySize = layers.reduce(0) { partial, layer in
            var size = partial
            size += layer.verticesBuffer?.allocatedSize ?? 0
            size += layer.indicesBuffer?.allocatedSize ?? 0
            size += layer.stylesBuffer?.allocatedSize ?? 0
            size += layer.overviewStyleMaskBuffer?.allocatedSize ?? 0
            return size
        }
        var extrudedSize = tileBuffers.extruded.verticesBuffer?.allocatedSize ?? 0
        extrudedSize += tileBuffers.extruded.indicesBuffer?.allocatedSize ?? 0
        extrudedSize += tileBuffers.extruded.stylesBuffer?.allocatedSize ?? 0
        let textLabelSets = [tileBuffers.textLabels.full,
                             tileBuffers.textLabels.reduced,
                             tileBuffers.textLabels.minimal]
        let textLabelsSize = textLabelSets.reduce(0) { partial, labelSet in
            var size = partial
            size += labelSet.labelsByStyleRuns.reduce(0) { $0 + ($1.localGlyphVerticesBuffer?.allocatedSize ?? 0) }
            size += labelSet.poiIconRuns.reduce(0) { $0 + ($1.localVerticesBuffer?.allocatedSize ?? 0) }
            return size
        }
        let roadLabelsSize = tileBuffers.roadLabels.localGlyphVerticesBuffer?.allocatedSize ?? 0
        return geometrySize + extrudedSize + textLabelsSize + roadLabelsSize
    }
}
