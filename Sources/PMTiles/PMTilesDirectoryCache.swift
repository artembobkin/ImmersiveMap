// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The leaf directories an archive client has read, held up to a cost
/// limit and evicted least recently used first. A leaf is keyed by its
/// offset in the leaf section, which names it uniquely within one archive.
///
/// Recency is a tick stored on each slot rather than a position in a list:
/// a read stays O(1), and the scan for the oldest slot runs only when an
/// insertion goes over the limit. Not thread-safe: the client confines it
/// to its state queue.
struct PMTilesDirectoryCache {
    private struct Slot {
        var directory: PMTilesDirectory
        var cost: Int
        var lastUsedTick: UInt64
    }

    let costLimit: Int
    private var slotsByOffset: [UInt64: Slot] = [:]
    private var tick: UInt64 = 0
    private(set) var totalCost = 0

    var count: Int {
        slotsByOffset.count
    }

    init(costLimit: Int) {
        self.costLimit = max(0, costLimit)
    }

    /// The directory at `offset`, marked as the most recently used.
    mutating func directory(atOffset offset: UInt64) -> PMTilesDirectory? {
        guard var slot = slotsByOffset[offset] else {
            return nil
        }
        tick &+= 1
        slot.lastUsedTick = tick
        slotsByOffset[offset] = slot
        return slot.directory
    }

    /// Stores `directory` at `offset`, then evicts the least recently used
    /// directories until the total fits the limit. A directory costlier than
    /// the whole limit is not kept.
    mutating func insert(_ directory: PMTilesDirectory, atOffset offset: UInt64, cost: Int) {
        let cost = max(0, cost)
        if let previous = slotsByOffset.removeValue(forKey: offset) {
            totalCost -= previous.cost
        }
        guard cost <= costLimit else {
            return
        }
        tick &+= 1
        slotsByOffset[offset] = Slot(directory: directory, cost: cost, lastUsedTick: tick)
        totalCost += cost
        while totalCost > costLimit,
              let oldest = slotsByOffset.min(by: { $0.value.lastUsedTick < $1.value.lastUsedTick }) {
            slotsByOffset.removeValue(forKey: oldest.key)
            totalCost -= oldest.value.cost
        }
    }

    mutating func removeAll() {
        slotsByOffset.removeAll()
        totalCost = 0
    }
}
