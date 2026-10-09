// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The per-frame collision solve: one strict rank order over base labels
/// and road instances, first placed keeps the space, a road instance is
/// accepted only
/// with all its glyph boxes, and the answer is the same whatever order the
/// inputs came in.
final class LabelCollisionSolverTests: XCTestCase {
    private let viewport = SIMD2<Float>(1000, 1000)

    private func rank(_ priority: Int, sort: Int = 0, key: UInt64) -> BaseLabelRank {
        BaseLabelRank(priority: priority, sortPriority: sort, key: key)
    }

    private func roadRank(_ priority: Int, key: UInt64) -> LabelCollisionRank {
        LabelCollisionRank(priority: priority, secondaryPriority: 0, sortPriority: 0, stableOrderKey: key)
    }

    /// Binds the base ranks in the order the working set would hand over.
    private func rebind(_ solver: LabelCollisionSolver, _ ranks: [BaseLabelRank]) {
        solver.rebindBase(ranks: ranks, order: BaseLabelRankOrder.sorted(ranks))
    }

    private func solve(solver: LabelCollisionSolver,
                       centers: [SIMD2<Float>],
                       halfSizes: [SIMD2<Float>]? = nil,
                       enabled: [Bool]? = nil,
                       roadItems: [LabelCollisionRoadItem] = [],
                       roadCenters: [SIMD2<Float>] = [],
                       roadHalfSizes: [SIMD2<Float>] = [],
                       roadCount: Int = 0) -> (base: [Bool], road: [Bool]) {
        var base: [Bool] = []
        var road = [Bool](repeating: false, count: roadCount)
        solver.solve(viewportSize: viewport,
                     cellSizePx: 32,
                     baseCenters: centers,
                     baseHalfSizes: halfSizes ?? Array(repeating: SIMD2<Float>(20, 10), count: centers.count),
                     baseEnabled: enabled ?? Array(repeating: true, count: centers.count),
                     roadItems: roadItems,
                     roadCenters: roadCenters,
                     roadHalfSizes: roadHalfSizes,
                     baseVisible: &base,
                     roadVisible: &road)
        return (base, road)
    }

    func testTheHigherRankKeepsTheSpaceWhateverTheIndexOrder() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(5, key: 1), rank(1, key: 2)])
        let result = solve(solver: solver, centers: [SIMD2<Float>(100, 100), SIMD2<Float>(110, 105)])
        XCTAssertEqual(result.base, [false, true], "Index 1 has the better rank and is placed first")
    }

    func testEqualRankFallsToTheStableKey() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(1, key: 20), rank(1, key: 10)])
        let result = solve(solver: solver, centers: [SIMD2<Float>(100, 100), SIMD2<Float>(110, 105)])
        XCTAssertEqual(result.base, [false, true])
    }

    func testTheSortPriorityOrdersBeforeTheKey() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(1, sort: 9, key: 1), rank(2, key: 2), rank(1, sort: 3, key: 3)])
        let result = solve(solver: solver, centers: [SIMD2<Float>(100, 100), SIMD2<Float>(105, 100), SIMD2<Float>(110, 100)])
        XCTAssertEqual(result.base, [false, false, true])
    }

    func testNonOverlappingLabelsAllShow() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(1, key: 1), rank(1, key: 2), rank(1, key: 3)])
        let result = solve(solver: solver, centers: [SIMD2<Float>(100, 100), SIMD2<Float>(300, 100), SIMD2<Float>(100, 300)])
        XCTAssertEqual(result.base, [true, true, true])
    }

    func testTouchingBoxesDoNotCollide() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(1, key: 1), rank(1, key: 2)])
        // Half width 20: centres 40 apart share an edge, and an edge is not an overlap.
        let result = solve(solver: solver, centers: [SIMD2<Float>(100, 100), SIMD2<Float>(140, 100)])
        XCTAssertEqual(result.base, [true, true])
    }

    func testDisabledAndOffscreenLabelsAreHiddenAndTakeNoSpace() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(0, key: 1), rank(0, key: 2), rank(5, key: 3)])
        let result = solve(solver: solver,
                           centers: [SIMD2<Float>(100, 100), SIMD2<Float>(-500, -500), SIMD2<Float>(105, 100)],
                           enabled: [false, true, true])
        XCTAssertEqual(result.base, [false, false, true],
                       "The disabled top-ranked label blocks nothing; the off-screen one is hidden without a fight")
    }

    func testABoxStraddlingTheViewportEdgeStillCounts() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(0, key: 1), rank(1, key: 2)])
        let result = solve(solver: solver, centers: [SIMD2<Float>(-5, 500), SIMD2<Float>(10, 500)])
        XCTAssertEqual(result.base, [true, false])
    }

    /// Two labels at one point never both show, whatever their keys: the
    /// working set has already left out the copies of one feature.
    func testLabelsOfTheSameKeyBlockEachOther() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(0, key: 7), rank(0, key: 7)])
        let result = solve(solver: solver, centers: [SIMD2<Float>(100, 100), SIMD2<Float>(100, 100)])
        XCTAssertEqual(result.base, [true, false])
    }

    /// A road instance's glyphs share its group and never block each other.
    func testARoadInstancesOwnGlyphsNeverBlockEachOther() {
        let solver = LabelCollisionSolver()
        rebind(solver, [])
        let roadCenters = [SIMD2<Float>(200, 500), SIMD2<Float>(205, 500)]
        let items = [LabelCollisionRoadItem(rank: roadRank(9, key: 100), groupId: 100, boxRange: 0..<2, targetIndex: 0)]
        let result = solve(solver: solver, centers: [],
                           roadItems: items, roadCenters: roadCenters,
                           roadHalfSizes: Array(repeating: SIMD2<Float>(12, 8), count: 2), roadCount: 1)
        XCTAssertEqual(result.road, [true])
    }

    func testARoadInstanceIsAcceptedOnlyWithAllItsGlyphs() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(0, key: 1)])
        // Base label at (100, 100); road instance A's glyphs run 200..260 (clear),
        // instance B's second glyph lands on the base label.
        let roadCenters = [SIMD2<Float>(200, 500), SIMD2<Float>(230, 500), SIMD2<Float>(260, 500),
                           SIMD2<Float>(400, 100), SIMD2<Float>(110, 100)]
        let roadHalf = Array(repeating: SIMD2<Float>(12, 8), count: roadCenters.count)
        let items = [LabelCollisionRoadItem(rank: roadRank(9, key: 100), groupId: 100, boxRange: 0..<3, targetIndex: 0),
                     LabelCollisionRoadItem(rank: roadRank(9, key: 101), groupId: 101, boxRange: 3..<5, targetIndex: 1)]
        let result = solve(solver: solver, centers: [SIMD2<Float>(100, 100)],
                           roadItems: items, roadCenters: roadCenters, roadHalfSizes: roadHalf, roadCount: 2)
        XCTAssertEqual(result.base, [true])
        XCTAssertEqual(result.road, [true, false])
    }

    func testRoadAndBaseLabelsShareOneRankOrder() {
        let solver = LabelCollisionSolver()
        rebind(solver, [rank(5, key: 1)])
        let roadCenters = [SIMD2<Float>(100, 100)]
        let items = [LabelCollisionRoadItem(rank: roadRank(1, key: 100), groupId: 100, boxRange: 0..<1, targetIndex: 0)]
        let result = solve(solver: solver, centers: [SIMD2<Float>(105, 100)],
                           roadItems: items, roadCenters: roadCenters, roadHalfSizes: [SIMD2<Float>(12, 8)], roadCount: 1)
        XCTAssertEqual(result.base, [false], "The road instance outranks the base label here")
        XCTAssertEqual(result.road, [true])
    }

    func testAnInstanceNotOfferedKeepsTheCallersValue() {
        let solver = LabelCollisionSolver()
        rebind(solver, [])
        var base: [Bool] = []
        var road = [false, true]
        solver.solve(viewportSize: viewport, cellSizePx: 32,
                     baseCenters: [], baseHalfSizes: [], baseEnabled: [],
                     roadItems: [LabelCollisionRoadItem(rank: roadRank(1, key: 5), groupId: 5, boxRange: 0..<1, targetIndex: 0)],
                     roadCenters: [SIMD2<Float>(100, 100)], roadHalfSizes: [SIMD2<Float>(5, 5)],
                     baseVisible: &base, roadVisible: &road)
        XCTAssertEqual(road, [true, true], "Index 1 was not offered and stays as it was")
    }

    func testRepeatedSolvesAreDeterministicAndReuseTheGrid() {
        let solver = LabelCollisionSolver()
        var generator = SystemRandomNumberGenerator()
        let count = 400
        var ranks: [BaseLabelRank] = []
        var centers: [SIMD2<Float>] = []
        for index in 0..<count {
            ranks.append(rank(index % 5, key: UInt64(index + 1)))
            centers.append(SIMD2<Float>(Float.random(in: 0..<1000, using: &generator), Float.random(in: 0..<1000, using: &generator)))
        }
        rebind(solver, ranks)
        let first = solve(solver: solver, centers: centers)
        let second = solve(solver: solver, centers: centers)
        XCTAssertEqual(first.base, second.base)
        XCTAssertTrue(first.base.contains(true))
        XCTAssertTrue(first.base.contains(false), "Four hundred boxes on a thousand-pixel square must collide somewhere")
        // Every shown pair is disjoint: the grid missed nothing.
        for a in 0..<count where first.base[a] {
            for b in (a + 1)..<count where first.base[b] {
                let delta = simd_abs(centers[a] - centers[b])
                XCTAssertFalse(delta.x < 40 && delta.y < 20, "\(a) and \(b) overlap yet both show")
            }
        }
    }
}
