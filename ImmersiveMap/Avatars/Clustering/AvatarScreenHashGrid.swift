// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarScreenHashGrid.swift
//  ImmersiveMap
//

import Foundation
import simd

/// Uniform hash grid over screen positions: the broad phase for the collision
/// and grouping solver. Any pair of points within distance <= cellSize is
/// guaranteed to land in adjacent (3x3) cells, so with
/// cellSize >= the maximum interaction distance the neighbor sweep is complete.
/// The layout is compact (counting sort): indices ascend within a cell, and
/// traversal is deterministic, independent of hash-table ordering. Neighbor
/// cells of every slot are precomputed, so hot queries by grid points never
/// hash coordinates at all.
struct AvatarScreenHashGrid {
    let cellSize: Float
    private let inverseCellSize: Float
    private var slotByCellKey: [Int64: Int]
    /// Cell offsets into entries: cell slot occupies starts[slot]..<starts[slot+1].
    private var starts: [Int]
    /// Point indices grouped by cell, ascending within each cell.
    private var entries: [Int]
    /// Cell slot of each point.
    private var slotForPoint: [Int]
    /// Up to 9 slots of non-empty neighbor cells (including the cell itself) per
    /// slot, flat in groups of 9; -1 means the neighbor cell is empty.
    private var neighborSlots: [Int32]

    init(positions: [SIMD2<Float>], cellSize: Float) {
        let safeCellSize = max(cellSize, 1.0)
        self.cellSize = safeCellSize
        let inverseCellSize = 1.0 / safeCellSize
        self.inverseCellSize = inverseCellSize

        var slotByCellKey = Dictionary<Int64, Int>(minimumCapacity: positions.count)
        var slotForPoint = [Int](repeating: 0, count: positions.count)
        var counts: [Int] = []
        var cellKeys: [Int64] = []
        for index in positions.indices {
            let key = Self.cellKey(position: positions[index], inverseCellSize: inverseCellSize)
            if let slot = slotByCellKey[key] {
                slotForPoint[index] = slot
                counts[slot] += 1
            } else {
                let slot = counts.count
                slotByCellKey[key] = slot
                slotForPoint[index] = slot
                counts.append(1)
                cellKeys.append(key)
            }
        }

        var starts = [Int](repeating: 0, count: counts.count + 1)
        for slot in counts.indices {
            starts[slot + 1] = starts[slot] + counts[slot]
        }

        var cursors = starts
        var entries = [Int](repeating: 0, count: positions.count)
        for index in positions.indices {
            let slot = slotForPoint[index]
            entries[cursors[slot]] = index
            cursors[slot] += 1
        }

        var neighborSlots = [Int32](repeating: -1, count: counts.count * 9)
        for slot in counts.indices {
            let key = cellKeys[slot]
            let cellX = Int32(truncatingIfNeeded: key >> 32)
            let cellY = Int32(truncatingIfNeeded: key)
            var offset = slot * 9
            for dy: Int32 in -1...1 {
                for dx: Int32 in -1...1 {
                    if let neighbor = slotByCellKey[Self.combine(cellX: cellX &+ dx,
                                                                 cellY: cellY &+ dy)] {
                        neighborSlots[offset] = Int32(neighbor)
                    }
                    offset += 1
                }
            }
        }

        self.slotByCellKey = slotByCellKey
        self.starts = starts
        self.entries = entries
        self.slotForPoint = slotForPoint
        self.neighborSlots = neighborSlots
    }

    /// Number of grid cells.
    var cellCount: Int {
        starts.count - 1
    }

    /// Slot of the cell containing the grid point with the given index.
    func cellSlot(ofPointAt index: Int) -> Int {
        slotForPoint[index]
    }

    /// Point indices of the cell at the given slot.
    func entries(inCellSlot slot: Int) -> ArraySlice<Int> {
        entries[starts[slot]..<starts[slot + 1]]
    }

    /// Slots of all cells whose population is at least the threshold.
    func cellSlots(withPopulationAtLeast threshold: Int) -> [Int] {
        var slots: [Int] = []
        for slot in 0..<cellCount where starts[slot + 1] - starts[slot] >= threshold {
            slots.append(slot)
        }
        return slots
    }

    /// Iterates the slots of the non-empty neighbor cells of a slot (including itself).
    func forEachNeighborSlot(of slot: Int, _ body: (Int) -> Void) {
        let base = slot * 9
        for offset in 0..<9 {
            let neighborSlot = Int(neighborSlots[base + offset])
            guard neighborSlot >= 0 else { continue }
            body(neighborSlot)
        }
    }

    /// Number of points in the cell containing the grid point with the given index.
    func cellPopulation(ofPointAt index: Int) -> Int {
        let slot = slotForPoint[index]
        return starts[slot + 1] - starts[slot]
    }

    /// Number of points in the cell containing an arbitrary position (0 if empty).
    func cellPopulation(at position: SIMD2<Float>) -> Int {
        guard let slot = slotByCellKey[Self.cellKey(position: position,
                                                    inverseCellSize: inverseCellSize)] else {
            return 0
        }
        return starts[slot + 1] - starts[slot]
    }

    /// Point indices of the cell containing the grid point with the given index.
    func cellEntries(ofPointAt index: Int) -> ArraySlice<Int> {
        let slot = slotForPoint[index]
        return entries[starts[slot]..<starts[slot + 1]]
    }

    /// Iterates the 3x3 neighborhood of a grid point: the body receives a slice of
    /// each non-empty neighbor cell (including its own) and an "is own cell" flag.
    func forEachNeighborCell(ofPointAt index: Int,
                             _ body: (ArraySlice<Int>, _ isOwnCell: Bool) -> Void) {
        let slot = slotForPoint[index]
        let base = slot * 9
        for offset in 0..<9 {
            let neighborSlot = Int(neighborSlots[base + offset])
            guard neighborSlot >= 0 else { continue }
            body(entries[starts[neighborSlot]..<starts[neighborSlot + 1]],
                 neighborSlot == slot)
        }
    }

    /// Collects neighbors of a grid point from the 3x3 neighborhood whose index is
    /// strictly greater than the given one, in ascending order. The buffer is
    /// cleared inside; the fixed ordering makes the (i, j > i) pair traversal
    /// bitwise reproducible.
    func collectNeighbors(ofPointAt index: Int,
                          greaterThan minIndex: Int,
                          into buffer: inout [Int]) {
        buffer.removeAll(keepingCapacity: true)
        forEachNeighborCell(ofPointAt: index) { cell, _ in
            for pointIndex in cell where pointIndex > minIndex {
                buffer.append(pointIndex)
            }
        }
        buffer.sort()
    }

    /// Collects candidates around an arbitrary position (3x3 neighborhood).
    /// For queries with points that are not part of the grid. The order is a fixed
    /// cell traversal (deterministic) but not sorted by index: all callers fold
    /// the candidates commutatively (max/min/union).
    func collectCandidates(around position: SIMD2<Float>,
                           into buffer: inout [Int]) {
        buffer.removeAll(keepingCapacity: true)
        let cellX = Self.cellCoordinate(position.x, inverseCellSize: inverseCellSize)
        let cellY = Self.cellCoordinate(position.y, inverseCellSize: inverseCellSize)
        for dy: Int32 in -1...1 {
            for dx: Int32 in -1...1 {
                guard let slot = slotByCellKey[Self.combine(cellX: cellX &+ dx,
                                                            cellY: cellY &+ dy)] else {
                    continue
                }
                buffer.append(contentsOf: entries[starts[slot]..<starts[slot + 1]])
            }
        }
    }

    private static func cellCoordinate(_ value: Float, inverseCellSize: Float) -> Int32 {
        Int32((value * inverseCellSize).rounded(.down))
    }

    private static func cellKey(position: SIMD2<Float>, inverseCellSize: Float) -> Int64 {
        combine(cellX: cellCoordinate(position.x, inverseCellSize: inverseCellSize),
                cellY: cellCoordinate(position.y, inverseCellSize: inverseCellSize))
    }

    private static func combine(cellX: Int32, cellY: Int32) -> Int64 {
        (Int64(cellX) << 32) | (Int64(UInt32(bitPattern: cellY)))
    }
}

/// Disjoint-set structure with an iterative find (the recursive variant
/// overflowed the stack on chains of tens of thousands of elements) and path
/// compression. Invariant: a component's root is its minimum index, so group
/// membership is deterministic and ordered by the smallest member.
struct AvatarDisjointSet {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root {
            root = parent[root]
        }
        var current = index
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let lhsRoot = find(lhs)
        let rhsRoot = find(rhs)
        guard lhsRoot != rhsRoot else { return }
        parent[max(lhsRoot, rhsRoot)] = min(lhsRoot, rhsRoot)
    }
}
