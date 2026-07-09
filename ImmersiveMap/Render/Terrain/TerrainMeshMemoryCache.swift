// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

final class TerrainMeshMemoryCache<Mesh> {
    private struct Entry {
        var mesh: Mesh
        var cost: Int
        var lastAccess: UInt64
    }

    private let maxCost: Int
    private var nextAccess: UInt64 = 0
    private var entriesByKey: [TerrainTileCacheKey: Entry] = [:]

    private(set) var totalCost: Int = 0

    init(maxCost: Int) {
        self.maxCost = max(0, maxCost)
    }

    func mesh(for key: TerrainTileCacheKey) -> Mesh? {
        guard var entry = entriesByKey[key] else {
            return nil
        }

        entry.lastAccess = nextAccessValue()
        entriesByKey[key] = entry
        return entry.mesh
    }

    func set(_ mesh: Mesh,
             for key: TerrainTileCacheKey,
             cost: Int) {
        let clampedCost = max(0, cost)
        if let existing = entriesByKey[key] {
            totalCost -= existing.cost
        }

        entriesByKey[key] = Entry(mesh: mesh,
                                  cost: clampedCost,
                                  lastAccess: nextAccessValue())
        totalCost += clampedCost
        evictIfNeeded(preserving: key)
    }

    func removeAll() {
        entriesByKey.removeAll()
        totalCost = 0
    }

    private func evictIfNeeded(preserving preservedKey: TerrainTileCacheKey) {
        while totalCost > maxCost,
              let victim = leastRecentlyUsedKey(excluding: preservedKey) {
            if let removed = entriesByKey.removeValue(forKey: victim) {
                totalCost -= removed.cost
            }
        }
    }

    private func leastRecentlyUsedKey(excluding preservedKey: TerrainTileCacheKey) -> TerrainTileCacheKey? {
        entriesByKey
            .filter { $0.key != preservedKey }
            .min { lhs, rhs in lhs.value.lastAccess < rhs.value.lastAccess }?
            .key
    }

    private func nextAccessValue() -> UInt64 {
        defer { nextAccess &+= 1 }
        return nextAccess
    }
}

