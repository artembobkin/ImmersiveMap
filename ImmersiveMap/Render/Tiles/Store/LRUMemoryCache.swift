// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct LRUMemoryCache<Key: Hashable, Value> {
    struct Entry {
        let key: Key
        let value: Value
        let cost: Int
    }

    // Recency хранится тиком на слоте, а не позицией в массиве: проба кэша
    // остаётся O(1), а поиск жертвы выполняется только при вытеснении.
    private struct Slot {
        var value: Value
        var cost: Int
        var lastUsedTick: UInt64
    }

    private let costLimit: Int
    private var slotsByKey: [Key: Slot] = [:]
    private var usageTick: UInt64 = 0

    private(set) var totalCost = 0

    var count: Int {
        slotsByKey.count
    }

    init(costLimit: Int) {
        self.costLimit = max(0, costLimit)
    }

    func cost(forKey key: Key) -> Int? {
        slotsByKey[key]?.cost
    }

    mutating func value(forKey key: Key) -> Value? {
        guard let index = slotsByKey.index(forKey: key) else {
            return nil
        }

        usageTick &+= 1
        slotsByKey.values[index].lastUsedTick = usageTick
        return slotsByKey.values[index].value
    }

    /// `evictionCostLimit` заменяет лимит вытеснения для этой вставки:
    /// вызывающий может расширить бюджет, например на стоимость pinned-записей.
    mutating func setValue(_ value: Value,
                           forKey key: Key,
                           cost: Int,
                           protectedKeys: Set<Key> = [],
                           evictionCostLimit: Int? = nil) -> [Entry]? {
        let normalizedCost = max(0, cost)
        if let existingSlot = slotsByKey[key] {
            totalCost -= existingSlot.cost
        }

        usageTick &+= 1
        slotsByKey[key] = Slot(value: value, cost: normalizedCost, lastUsedTick: usageTick)
        totalCost += normalizedCost

        let evictedEntries = evict(toCost: max(0, evictionCostLimit ?? costLimit),
                                   protectedKeys: protectedKeys,
                                   insertedKey: key,
                                   keepAtLeastOneEntry: true)
        return evictedEntries.isEmpty ? nil : evictedEntries
    }

    mutating func trim(toCost targetCost: Int,
                       protectedKeys: Set<Key> = []) -> [Entry] {
        evict(toCost: max(0, targetCost),
              protectedKeys: protectedKeys,
              insertedKey: nil,
              keepAtLeastOneEntry: false)
    }

    mutating func removeAll() -> [Entry] {
        let removedEntries = slotsByKey
            .sorted { $0.value.lastUsedTick < $1.value.lastUsedTick }
            .map { Entry(key: $0.key, value: $0.value.value, cost: $0.value.cost) }
        slotsByKey.removeAll(keepingCapacity: false)
        totalCost = 0
        return removedEntries
    }

    private mutating func evict(toCost targetCost: Int,
                                protectedKeys: Set<Key>,
                                insertedKey: Key?,
                                keepAtLeastOneEntry: Bool) -> [Entry] {
        var evictedEntries: [Entry] = []
        let minimumCount = keepAtLeastOneEntry ? 1 : 0
        while totalCost > targetCost, slotsByKey.count > minimumCount {
            var victimKey: Key?
            var victimTick = UInt64.max
            for (key, slot) in slotsByKey {
                if key == insertedKey || protectedKeys.contains(key) {
                    continue
                }
                if slot.lastUsedTick < victimTick {
                    victimTick = slot.lastUsedTick
                    victimKey = key
                }
            }

            // Все оставшиеся записи защищены - допускаем перерасход лимита.
            guard let victimKey,
                  let victimSlot = slotsByKey.removeValue(forKey: victimKey) else {
                break
            }
            totalCost -= victimSlot.cost
            evictedEntries.append(Entry(key: victimKey, value: victimSlot.value, cost: victimSlot.cost))
        }
        return evictedEntries
    }
}
