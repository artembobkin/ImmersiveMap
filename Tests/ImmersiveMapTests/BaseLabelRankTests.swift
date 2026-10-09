// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A base label's rank packed into one number, and a set's rank order made
/// by merging its tiles' orders instead of sorting the set.
final class BaseLabelRankTests: XCTestCase {
    func testThePackedPrioritiesKeepTheirOrderAcrossSigns() {
        let values = [Int.min, -70_000, -1, 0, 1, 20_000, 70_000, Int.max]
        for lhs in values {
            for rhs in values {
                let left = BaseLabelRank(priority: lhs, sortPriority: 0, key: 0)
                let right = BaseLabelRank(priority: rhs, sortPriority: 0, key: 0)
                XCTAssertEqual(BaseLabelRank.precedes(left, right), Int32(clamping: lhs) < Int32(clamping: rhs),
                               "\(lhs) against \(rhs)")
            }
        }
    }

    func testTheCollisionPriorityOutranksTheSortPriorityWhichOutranksTheKey() {
        XCTAssertTrue(BaseLabelRank.precedes(BaseLabelRank(priority: 1, sortPriority: 900, key: 9),
                                             BaseLabelRank(priority: 2, sortPriority: -5, key: 1)))
        XCTAssertTrue(BaseLabelRank.precedes(BaseLabelRank(priority: 1, sortPriority: -3, key: 9),
                                             BaseLabelRank(priority: 1, sortPriority: 4, key: 1)))
        XCTAssertTrue(BaseLabelRank.precedes(BaseLabelRank(priority: 1, sortPriority: 4, key: 1),
                                             BaseLabelRank(priority: 1, sortPriority: 4, key: 9)))
        XCTAssertFalse(BaseLabelRank.precedes(BaseLabelRank(priority: 1, sortPriority: 4, key: 1),
                                              BaseLabelRank(priority: 1, sortPriority: 4, key: 1)))
    }

    func testTheRankGivesBackItsCollisionPriority() {
        for priority in [-70_000, -1, 0, 50_072, Int(Int32.max)] {
            XCTAssertEqual(BaseLabelRank(priority: priority, sortPriority: 7, key: 0).priority, priority)
        }
        XCTAssertEqual(BaseLabelRank(priority: .max, sortPriority: 0, key: 0).priority, Int(Int32.max))
    }

    /// Runs of every length, an empty one and an odd count among them,
    /// merge into the order a sort of the whole gives.
    func testMergingTheRunsGivesTheSortedOrder() {
        var generator = SeededGenerator(seed: 7)
        for runCount in [1, 2, 3, 5, 8, 13] {
            var ranks: [BaseLabelRank] = []
            var order: [Int32] = []
            var runs: [Range<Int>] = []
            for run in 0..<runCount {
                let length = run == 1 ? 0 : Int.random(in: 1...40, using: &generator)
                let start = ranks.count
                for _ in 0..<length {
                    ranks.append(BaseLabelRank(priority: Int.random(in: 0...6, using: &generator),
                                               sortPriority: Int.random(in: -3...3, using: &generator),
                                               key: UInt64.random(in: 1...20, using: &generator)))
                }
                let tileRanks = Array(ranks[start...])
                order.append(contentsOf: BaseLabelRankOrder.sorted(tileRanks).map { $0 + Int32(start) })
                runs.append(start..<ranks.count)
            }
            BaseLabelRankOrder.mergeRuns(&order, runs: runs, ranks: ranks)
            XCTAssertEqual(order, BaseLabelRankOrder.sorted(ranks), "\(runCount) runs")
        }
    }

    /// Two labels of one rank keep the earlier run's first.
    func testATieKeepsTheEarlierRunFirst() {
        let rank = BaseLabelRank(priority: 3, sortPriority: 0, key: 7)
        let ranks = [BaseLabelRank(priority: 4, sortPriority: 0, key: 1), rank, rank]
        var order: [Int32] = [1, 0, 2]
        BaseLabelRankOrder.mergeRuns(&order, runs: [0..<2, 2..<3], ranks: ranks)
        XCTAssertEqual(order, [1, 2, 0])
    }
}

/// A small deterministic generator, so a failing case is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
