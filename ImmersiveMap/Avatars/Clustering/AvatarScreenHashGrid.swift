// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarScreenHashGrid.swift
//  ImmersiveMap
//

import Foundation
import simd

/// Равномерная хеш-сетка по экранным позициям: broad-phase для солвера
/// коллизий и группировки. Любая пара точек на дистанции <= cellSize
/// гарантированно оказывается в соседних (3x3) ячейках, поэтому при
/// cellSize >= максимальной дистанции взаимодействия перебор соседей полон.
/// Раскладка компактная (counting sort): внутри ячейки индексы возрастают,
/// обход детерминирован и не зависит от порядка хеш-таблицы. Соседние ячейки
/// каждого слота вычислены заранее - горячие запросы по точкам сетки не
/// хешируют координаты вовсе.
struct AvatarScreenHashGrid {
    let cellSize: Float
    private let inverseCellSize: Float
    private var slotByCellKey: [Int64: Int]
    /// Смещения ячеек в entries: ячейка slot занимает starts[slot]..<starts[slot+1].
    private var starts: [Int]
    /// Индексы точек, сгруппированные по ячейкам, внутри ячейки по возрастанию.
    private var entries: [Int]
    /// Слот ячейки каждой точки.
    private var slotForPoint: [Int]
    /// До 9 слотов непустых соседних ячеек (включая свою) на каждый слот,
    /// плоско по 9; -1 - соседняя ячейка пуста.
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

    /// Число ячеек сетки.
    var cellCount: Int {
        starts.count - 1
    }

    /// Слот ячейки, содержащей точку сетки с данным индексом.
    func cellSlot(ofPointAt index: Int) -> Int {
        slotForPoint[index]
    }

    /// Индексы точек ячейки слота.
    func entries(inCellSlot slot: Int) -> ArraySlice<Int> {
        entries[starts[slot]..<starts[slot + 1]]
    }

    /// Слоты всех ячеек с населением не меньше порога.
    func cellSlots(withPopulationAtLeast threshold: Int) -> [Int] {
        var slots: [Int] = []
        for slot in 0..<cellCount where starts[slot + 1] - starts[slot] >= threshold {
            slots.append(slot)
        }
        return slots
    }

    /// Обходит слоты непустых соседних ячеек слота (включая его самого).
    func forEachNeighborSlot(of slot: Int, _ body: (Int) -> Void) {
        let base = slot * 9
        for offset in 0..<9 {
            let neighborSlot = Int(neighborSlots[base + offset])
            guard neighborSlot >= 0 else { continue }
            body(neighborSlot)
        }
    }

    /// Число точек в ячейке, содержащей точку сетки с данным индексом.
    func cellPopulation(ofPointAt index: Int) -> Int {
        let slot = slotForPoint[index]
        return starts[slot + 1] - starts[slot]
    }

    /// Число точек в ячейке, содержащей произвольную позицию (0, если пуста).
    func cellPopulation(at position: SIMD2<Float>) -> Int {
        guard let slot = slotByCellKey[Self.cellKey(position: position,
                                                    inverseCellSize: inverseCellSize)] else {
            return 0
        }
        return starts[slot + 1] - starts[slot]
    }

    /// Индексы точек ячейки, содержащей точку сетки с данным индексом.
    func cellEntries(ofPointAt index: Int) -> ArraySlice<Int> {
        let slot = slotForPoint[index]
        return entries[starts[slot]..<starts[slot + 1]]
    }

    /// Обходит 3x3 окрестность точки сетки: тело получает слайс каждой
    /// непустой соседней ячейки (включая свою) и признак «это своя ячейка».
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

    /// Собирает соседей точки сетки из 3x3 окрестности с индексом строго
    /// больше заданного, по возрастанию. Буфер очищается внутри; порядок
    /// фиксирован, что делает обход пар (i, j > i) побитово воспроизводимым.
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

    /// Собирает кандидатов вокруг произвольной позиции (3x3 окрестность).
    /// Для запросов точками, не входящими в сетку. Порядок - фиксированный
    /// обход ячеек (детерминирован), но не отсортирован по индексу: все
    /// вызывающие сворачивают кандидатов коммутативно (max/min/union).
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

/// Система непересекающихся множеств с итеративным find (рекурсивный вариант
/// переполнял стек на цепочках в десятки тысяч элементов) и сжатием путей.
/// Инвариант: корень компоненты - минимальный индекс, поэтому состав групп
/// детерминирован и упорядочен по наименьшему участнику.
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
