// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  BaseLabelTileArena.swift
//  ImmersiveMap
//

import Foundation

final class BaseLabelTileArena {
    struct Allocation: Equatable {
        let start: Int
        let capacity: Int
    }

    private var freeRangeStartsByCapacity: [Int: [Int]] = [:]
    private var freeRangeCapacityByStart: [Int: Int] = [:]
    private var rangeSpanCount: Int = 0

    private var freeTileSlots: Set<UInt32> = []
    private var nextTileSlot: UInt32 = 0

    var activeRangeSpanCount: Int {
        rangeSpanCount
    }

    var activeTileSlotSpanCount: Int {
        Int(nextTileSlot)
    }

    func allocateRange(requiredCount: Int) -> Allocation {
        let bucketCapacity = bucketCapacity(for: requiredCount)
        if var starts = freeRangeStartsByCapacity[bucketCapacity], let reusedStart = starts.popLast() {
            freeRangeStartsByCapacity[bucketCapacity] = starts.isEmpty ? nil : starts
            freeRangeCapacityByStart.removeValue(forKey: reusedStart)
            return Allocation(start: reusedStart, capacity: bucketCapacity)
        }

        let allocation = Allocation(start: rangeSpanCount, capacity: bucketCapacity)
        rangeSpanCount += bucketCapacity
        return allocation
    }

    func releaseRange(_ allocation: Allocation) {
        guard allocation.capacity > 0 else {
            return
        }

        let allocationEnd = allocation.start + allocation.capacity
        if allocationEnd == rangeSpanCount {
            rangeSpanCount = allocation.start
            trimFreeRangeTail()
            return
        }

        freeRangeCapacityByStart[allocation.start] = allocation.capacity
        freeRangeStartsByCapacity[allocation.capacity, default: []].append(allocation.start)
    }

    func allocateTileSlot() -> UInt32 {
        if let reusedSlot = freeTileSlots.popFirst() {
            return reusedSlot
        }

        let slot = nextTileSlot
        nextTileSlot &+= 1
        return slot
    }

    func releaseTileSlot(_ slot: UInt32) {
        guard nextTileSlot > 0 else {
            return
        }

        if slot + 1 == nextTileSlot {
            nextTileSlot = slot
            trimFreeTileSlotTail()
            return
        }

        freeTileSlots.insert(slot)
    }

    func reset() {
        freeRangeStartsByCapacity.removeAll(keepingCapacity: false)
        freeRangeCapacityByStart.removeAll(keepingCapacity: false)
        rangeSpanCount = 0
        freeTileSlots.removeAll(keepingCapacity: false)
        nextTileSlot = 0
    }

    private func trimFreeRangeTail() {
        while let tailRange = freeRangeCapacityByStart.first(where: { $0.key + $0.value == rangeSpanCount }) {
            freeRangeCapacityByStart.removeValue(forKey: tailRange.key)
            removeFreeRangeStart(tailRange.key, capacity: tailRange.value)
            rangeSpanCount = tailRange.key
        }
    }

    private func trimFreeTileSlotTail() {
        while nextTileSlot > 0 {
            let candidate = nextTileSlot - 1
            if freeTileSlots.remove(candidate) == nil {
                return
            }
            nextTileSlot = candidate
        }
    }

    private func removeFreeRangeStart(_ start: Int, capacity: Int) {
        guard var starts = freeRangeStartsByCapacity[capacity] else {
            return
        }
        starts.removeAll { $0 == start }
        freeRangeStartsByCapacity[capacity] = starts.isEmpty ? nil : starts
    }

    private func bucketCapacity(for requiredCount: Int) -> Int {
        var candidate = 1
        let requested = max(1, requiredCount)
        while candidate < requested {
            let (next, overflow) = candidate.multipliedReportingOverflow(by: 2)
            if overflow {
                return requested
            }
            candidate = next
        }
        return candidate
    }
}
