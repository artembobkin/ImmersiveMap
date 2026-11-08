// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A label on a roof rises with the buildings drawn under it, by the tile
/// and the quarter that draw them, whichever tile the label comes from.
final class BuildingRiseCoverageTests: XCTestCase {
    private let cell = Tile(x: 9908, y: 5140, z: 14)
    /// The cell's north-west and north-east children.
    private let northWest = Tile(x: 19816, y: 10280, z: 15)
    private let northEast = Tile(x: 19817, y: 10280, z: 15)

    /// The cell draws its southern quarters, its two northern children
    /// draw theirs.
    private var coverage: BuildingRiseCoverage {
        var coverage = BuildingRiseCoverage()
        coverage.add(tile: cell, quarters: 0b1100, rise: 0.5)
        coverage.add(tile: northWest, quarters: TileQuarters.all, rise: 1)
        coverage.add(tile: northEast, quarters: TileQuarters.all, rise: 0.75)
        return coverage
    }

    func testALabelOfTheCellRisesWithTheTileThatDrawsItsQuarter() {
        XCTAssertEqual(coverage.rise(tile: cell, uv: SIMD2(0.25, 0.75)), 0.5, "A quarter the cell draws")
        XCTAssertEqual(coverage.rise(tile: cell, uv: SIMD2(0.25, 0.25)), 1, "The north-west child's")
        XCTAssertEqual(coverage.rise(tile: cell, uv: SIMD2(0.75, 0.25)), 0.75, "The north-east child's")
    }

    func testALabelOfAChildRisesWithTheQuarterOfTheCellOverIt() {
        let southWest = Tile(x: 19816, y: 10281, z: 15)
        XCTAssertEqual(coverage.rise(tile: southWest, uv: SIMD2(0.5, 0.5)), 0.5)
        XCTAssertEqual(coverage.rise(tile: northWest, uv: SIMD2(0.5, 0.5)), 1, "Its own")
    }

    func testALabelWhereNoBuildingsDrawStaysOnTheGround() {
        var coverage = BuildingRiseCoverage()
        coverage.add(tile: cell, quarters: 0b0001, rise: 1)
        XCTAssertEqual(coverage.rise(tile: cell, uv: SIMD2(0.75, 0.75)), 0)
        XCTAssertEqual(coverage.rise(tile: Tile(x: 19817, y: 10281, z: 15), uv: SIMD2(0.5, 0.5)), 0)
        XCTAssertEqual(coverage.rise(tile: Tile(x: 0, y: 0, z: 15), uv: SIMD2(0.5, 0.5)), 0, "Elsewhere")
        XCTAssertEqual(BuildingRiseCoverage.none.rise(tile: cell, uv: SIMD2(0.5, 0.5)), 0)
    }

    /// Two world copies of one tile: the higher rise, the quarters of both.
    func testTwoCopiesOfATileJoin() {
        var coverage = BuildingRiseCoverage()
        coverage.add(tile: cell, quarters: 0b0001, rise: 0.25)
        coverage.add(tile: cell, quarters: 0b1000, rise: 0.5)
        XCTAssertEqual(coverage.rise(tile: cell, uv: SIMD2(0.25, 0.25)), 0.5)
        XCTAssertEqual(coverage.rise(tile: cell, uv: SIMD2(0.75, 0.75)), 0.5)
        XCTAssertEqual(coverage.rise(tile: cell, uv: SIMD2(0.75, 0.25)), 0)
    }
}
