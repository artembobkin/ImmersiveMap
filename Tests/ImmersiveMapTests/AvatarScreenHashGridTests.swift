// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class AvatarScreenHashGridTests: XCTestCase {
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Полнота broad-phase: пары в пределах cellSize через сетку совпадают с
    /// полным перебором - и по составу, и по порядку обхода (i, j возрастают).
    func testNeighborPairsMatchBruteForceIncludingOrder() {
        var generator = SplitMix(state: 99)
        let positions = (0..<600).map { _ in
            SIMD2(Float.random(in: -500...1500, using: &generator),
                  Float.random(in: -400...900, using: &generator))
        }
        let interactionRadius: Float = 130.0
        let grid = AvatarScreenHashGrid(positions: positions, cellSize: interactionRadius)

        var bruteForcePairs: [[Int]] = []
        for lhs in positions.indices {
            for rhs in (lhs + 1)..<positions.count
            where simd_length(positions[lhs] - positions[rhs]) <= interactionRadius {
                bruteForcePairs.append([lhs, rhs])
            }
        }

        var gridPairs: [[Int]] = []
        var neighbors: [Int] = []
        for lhs in positions.indices {
            grid.collectNeighbors(ofPointAt: lhs, greaterThan: lhs, into: &neighbors)
            for rhs in neighbors
            where simd_length(positions[lhs] - positions[rhs]) <= interactionRadius {
                gridPairs.append([lhs, rhs])
            }
        }

        XCTAssertEqual(gridPairs, bruteForcePairs)
    }

    func testNegativeCoordinatesAndCellBoundaries() {
        // Точки около нуля и на границах ячеек: floor-квантование не должен
        // склеивать ячейки -1 и 0.
        let positions: [SIMD2<Float>] = [
            SIMD2(-0.5, -0.5),
            SIMD2(0.5, 0.5),
            SIMD2(-100.0, 0.0),
            SIMD2(100.0, 0.0),
            SIMD2(0.0, 0.0)
        ]
        let grid = AvatarScreenHashGrid(positions: positions, cellSize: 100.0)

        // Точка 3 на (100, 0) лежит в ячейке (1, 0) - вне 3x3 окрестности
        // ячейки (-1, -1); её дистанция 100.5 > cellSize, полнота не нарушена.
        var neighbors: [Int] = []
        grid.collectNeighbors(ofPointAt: 0, greaterThan: -1, into: &neighbors)
        XCTAssertEqual(neighbors, [0, 1, 2, 4])

        XCTAssertEqual(grid.cellPopulation(at: SIMD2(0.5, 0.5)), 2)
        XCTAssertEqual(grid.cellPopulation(at: SIMD2(-0.5, -0.5)), 1)
        XCTAssertEqual(grid.cellPopulation(at: SIMD2(9999, 9999)), 0)
    }

    func testEmptyAndSinglePoint() {
        let empty = AvatarScreenHashGrid(positions: [], cellSize: 50.0)
        var neighbors: [Int] = [1, 2, 3]
        empty.collectCandidates(around: SIMD2(0, 0), into: &neighbors)
        XCTAssertTrue(neighbors.isEmpty)

        let single = AvatarScreenHashGrid(positions: [SIMD2(10, 10)], cellSize: 50.0)
        single.collectNeighbors(ofPointAt: 0, greaterThan: 0, into: &neighbors)
        XCTAssertTrue(neighbors.isEmpty)
        single.collectNeighbors(ofPointAt: 0, greaterThan: -1, into: &neighbors)
        XCTAssertEqual(neighbors, [0])
        single.collectCandidates(around: SIMD2(12, 8), into: &neighbors)
        XCTAssertEqual(neighbors, [0])
    }

    func testDensePileKeepsAllEntriesInOneNeighborhood() {
        let positions: [SIMD2<Float>] = (0..<10_000).map { index in
            let x = Float(index % 100) * 0.1
            let y = Float(index / 100) * 0.1
            return SIMD2<Float>(x, y)
        }
        let grid = AvatarScreenHashGrid(positions: positions, cellSize: 64.0)
        XCTAssertEqual(grid.cellPopulation(at: SIMD2(5, 5)), 10_000)

        var neighbors: [Int] = []
        grid.collectNeighbors(ofPointAt: 0, greaterThan: 9_000, into: &neighbors)
        XCTAssertEqual(neighbors, Array(9_001..<10_000))
        XCTAssertEqual(grid.cellPopulation(ofPointAt: 42), 10_000)
    }

    /// Итеративный find: цепочка объединений в 50k элементов не роняет стек
    /// (рекурсивная реализация здесь падала).
    func testDisjointSetSurvivesDeepChain() {
        let count = 50_000
        var set = AvatarDisjointSet(count: count)
        for index in stride(from: count - 2, through: 0, by: -1) {
            set.union(index, index + 1)
        }
        XCTAssertEqual(set.find(count - 1), 0)
        XCTAssertEqual(set.find(count / 2), 0)
        XCTAssertEqual(set.find(0), 0)
    }

    func testDisjointSetRootIsMinimumIndex() {
        var set = AvatarDisjointSet(count: 6)
        set.union(4, 5)
        set.union(2, 4)
        XCTAssertEqual(set.find(5), 2)
        set.union(5, 1)
        XCTAssertEqual(set.find(4), 1)
        XCTAssertEqual(set.find(0), 0)
        XCTAssertEqual(set.find(3), 3)
    }
}
