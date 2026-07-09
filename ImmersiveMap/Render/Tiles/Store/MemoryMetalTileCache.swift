// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

class MemoryMetalTileCache {
    private var cache: LRUMemoryCache<Tile, MetalTile>
    private let costLimit: Int
    private let stateLock = NSLock()
    private let tileTraceRecorder: TileTraceRecorder
    // Тайлы текущего demanded-набора: не вытесняются ни при вставке, ни при trim,
    // иначе при рабочем наборе больше лимита кэш пинг-понгует видимыми тайлами.
    private var protectedTiles: Set<Tile> = []
    private var mutationVersion: UInt64 = 0

    init(maxCacheSizeInBytes: Int, tileTraceRecorder: TileTraceRecorder) {
        self.costLimit = maxCacheSizeInBytes
        self.tileTraceRecorder = tileTraceRecorder
        self.cache = LRUMemoryCache(costLimit: maxCacheSizeInBytes)
    }

    // Меняется при каждой мутации содержимого (вставка/вытеснение/очистка) -
    // ключ для dirty-гейтов, зависящих от готовности тайлов.
    var contentVersion: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mutationVersion
    }

    func updateProtectedTiles(_ tiles: Set<Tile>) {
        let result: (evicted: [LRUMemoryCache<Tile, MetalTile>.Entry], totalCost: Int, count: Int)
        stateLock.lock()
        protectedTiles = tiles
        // Overshoot от защиты demanded-тайлов ликвидируется, как только набор
        // сжался: иначе кэш держал бы превышение лимита до следующей вставки
        // или memory warning. В обычном случае (totalCost <= limit) - no-op.
        if cache.totalCost > costLimit {
            let evicted = cache.trim(toCost: costLimit, protectedKeys: protectedTiles)
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

    // Сбрасывает кэш до доли лимита, сохраняя защищённые (видимые) тайлы -
    // мягкая реакция на memory warning вместо полной очистки и пустой карты.
    func trim(toFractionOfLimit fraction: Double) {
        let targetCost = Int(Double(costLimit) * max(0.0, min(1.0, fraction)))
        let result: (evicted: [LRUMemoryCache<Tile, MetalTile>.Entry], totalCost: Int, count: Int)
        stateLock.lock()
        let evicted = cache.trim(toCost: targetCost, protectedKeys: protectedTiles)
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
        let evictedEntries = cache.setValue(tile, forKey: key, cost: cost, protectedKeys: protectedTiles) ?? []
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
        mutationVersion &+= 1
        return snapshot
    }
    
    private func estimateTileByteSize(_ tile: MetalTile) -> Int {
        let tileBuffers = tile.tileBuffers
        
        let layers = [tileBuffers.ground]
            + tileBuffers.roads.drawOrderBuckets.flatMap(\.drawOrderLayers)
            + [tileBuffers.bridgeOverlay]
        let geometrySize = layers.reduce(0) { partial, layer in
            partial + layer.verticesBuffer.allocatedSize
                + layer.indicesBuffer.allocatedSize
                + layer.stylesBuffer.allocatedSize
                + layer.overviewStyleMaskBuffer.allocatedSize
        }
        let extrudedSize = tileBuffers.extruded.verticesBuffer.allocatedSize
            + tileBuffers.extruded.indicesBuffer.allocatedSize
            + tileBuffers.extruded.stylesBuffer.allocatedSize
        let textLabelSets = [tileBuffers.textLabels.full,
                             tileBuffers.textLabels.reduced,
                             tileBuffers.textLabels.minimal]
        let textLabelsSize = textLabelSets.reduce(0) { partial, labelSet in
            partial
                + labelSet.labelsByStyleRuns.reduce(0) { $0 + ($1.localGlyphVerticesBuffer?.allocatedSize ?? 0) }
                + labelSet.poiIconRuns.reduce(0) { $0 + ($1.localVerticesBuffer?.allocatedSize ?? 0) }
        }
        let roadLabelsSize = tileBuffers.roadLabels.localGlyphVerticesBuffer?.allocatedSize ?? 0
        return geometrySize + extrudedSize + textLabelsSize + roadLabelsSize
    }
}
