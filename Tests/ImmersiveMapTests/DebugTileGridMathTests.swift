// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class DebugTileGridMathTests: XCTestCase {
    func testCellBoundsPartitionTheTileWithoutGapOrOverlap() {
        for density in DebugTileGridDensity.options {
            var expectedNext = 0
            for index in 0..<density {
                let bounds = DebugTileGridMath.cellBounds(index: index, density: density)
                XCTAssertEqual(bounds.lo, expectedNext,
                               "density \(density) cell \(index) does not continue the previous cell")
                XCTAssertGreaterThan(bounds.hi, bounds.lo,
                                     "density \(density) cell \(index) is empty")
                expectedNext = bounds.hi + 1
            }
            XCTAssertEqual(expectedNext, DebugTileGridMath.tileExtent,
                           "density \(density) does not reach the tile extent")
        }
    }

    func testCellBoundsForSixRoundTheUnevenPartition() {
        let expected = [(0, 682), (683, 1364), (1365, 2047), (2048, 2730), (2731, 3412), (3413, 4095)]
        for index in expected.indices {
            let bounds = DebugTileGridMath.cellBounds(index: index, density: 6)
            XCTAssertEqual(bounds.lo, expected[index].0)
            XCTAssertEqual(bounds.hi, expected[index].1)
        }
    }

    func testCellCodeCountsColumnsFromWestAndRowsFromSouth() {
        XCTAssertEqual(DebugTileGridMath.cellCode(column: 0, row: 0), "A1")
        XCTAssertEqual(DebugTileGridMath.cellCode(column: 2, row: 3), "C4")
        XCTAssertEqual(DebugTileGridMath.cellCode(column: 7, row: 7), "H8")
    }

    /// The exact strings a screenshot carries. An agent reads these back to find the
    /// geometry, so they are a contract and not a formatting detail.
    func testCellLabelLinesAreSelfSufficient() {
        let lines = DebugTileGridMath.cellLabelLines(tile: Tile(x: 39615, y: 20486, z: 16),
                                                     column: 2,
                                                     row: 3,
                                                     density: 6)

        XCTAssertEqual(lines, ["39615/20486/16", "C4", "x1365-2047", "y2048-2730"])
    }

    /// A substituted slot draws a coarser tile's geometry, so the stamp has to name
    /// the tile the pixels actually came from as well as the slot they fill.
    func testSubstitutedCellNamesTheSourceTile() {
        let lines = DebugTileGridMath.cellLabelLines(tile: Tile(x: 39615, y: 20486, z: 16),
                                                     column: 2,
                                                     row: 3,
                                                     density: 6,
                                                     sourceTile: Tile(x: 19807, y: 10243, z: 15))

        XCTAssertEqual(lines, ["39615/20486/16", "C4", "x1365-2047", "y2048-2730", "src 19807/10243/15"])
    }

    func testExactCellDoesNotRepeatItsOwnTileAsASource() {
        let tile = Tile(x: 39615, y: 20486, z: 16)
        let lines = DebugTileGridMath.cellLabelLines(tile: tile,
                                                     column: 2,
                                                     row: 3,
                                                     density: 6,
                                                     sourceTile: tile)

        XCTAssertEqual(lines.count, 4)
    }

    func testCellLabelBoundsMatchTheCellCode() {
        for density in DebugTileGridDensity.options {
            for row in 0..<density {
                for column in 0..<density {
                    let lines = DebugTileGridMath.cellLabelLines(tile: Tile(x: 1, y: 2, z: 3),
                                                                 column: column,
                                                                 row: row,
                                                                 density: density)
                    let xBounds = DebugTileGridMath.cellBounds(index: column, density: density)
                    let yBounds = DebugTileGridMath.cellBounds(index: row, density: density)
                    XCTAssertEqual(lines[1], DebugTileGridMath.cellCode(column: column, row: row))
                    XCTAssertEqual(lines[2], "x\(xBounds.lo)-\(xBounds.hi)")
                    XCTAssertEqual(lines[3], "y\(yBounds.lo)-\(yBounds.hi)")
                }
            }
        }
    }

    /// The row index counts north from the south edge while `uv.y` counts south from
    /// the north edge, so the first row has to sit at the bottom of the tile in UV.
    func testCellUVRectMirrorsRowsAgainstTileUV() {
        let bottomRow = DebugTileGridMath.cellUVRect(column: 0, row: 0, density: 4)
        XCTAssertEqual(bottomRow.minU, 0.0, accuracy: 1e-6)
        XCTAssertEqual(bottomRow.maxU, 0.25, accuracy: 1e-6)
        XCTAssertEqual(bottomRow.minV, 0.75, accuracy: 1e-6)
        XCTAssertEqual(bottomRow.maxV, 1.0, accuracy: 1e-6)

        let topRow = DebugTileGridMath.cellUVRect(column: 3, row: 3, density: 4)
        XCTAssertEqual(topRow.minU, 0.75, accuracy: 1e-6)
        XCTAssertEqual(topRow.maxU, 1.0, accuracy: 1e-6)
        XCTAssertEqual(topRow.minV, 0.0, accuracy: 1e-6)
        XCTAssertEqual(topRow.maxV, 0.25, accuracy: 1e-6)
    }

    func testGridSegmentsCoverEveryLineAndStayInsideTheTile() {
        let segmentsPerLine = 8
        let density = 6
        let segments = DebugTileGridMath.makeGridSegments(density: density,
                                                          segmentCountPerEdge: segmentsPerLine)

        XCTAssertEqual(segments.count, (density + 1) * 2 * segmentsPerLine)
        for segment in segments {
            for point in [segment.start, segment.end] {
                XCTAssertGreaterThanOrEqual(point.x, 0.0)
                XCTAssertLessThanOrEqual(point.x, 1.0)
                XCTAssertGreaterThanOrEqual(point.y, 0.0)
                XCTAssertLessThanOrEqual(point.y, 1.0)
            }
        }
    }

    func testOnlyTheOutermostGridLinesAreBorders() {
        let density = 4
        let segments = DebugTileGridMath.makeGridSegments(density: density, segmentCountPerEdge: 1)
        let borderPositions = Set(segments.filter(\.isBorder).flatMap { [$0.start.x, $0.start.y] })

        XCTAssertEqual(borderPositions, [0.0, 1.0])
        XCTAssertEqual(segments.filter(\.isBorder).count, 2 * 2)
        XCTAssertEqual(segments.filter { $0.isBorder == false }.count, (density - 1) * 2)
    }

    /// The plate covers the widest line and the full stack, and nothing beyond it
    /// plus the padding: it is there to stop map labels muddying the stamp, not to
    /// black out the cell.
    func testStampPlateCoversEveryLineAndOnlyThePadding() {
        let plate = DebugTileGridMath.makeStampPlate(
            lineAnchors: [SIMD2<Float>(0.5, 0.40),
                          SIMD2<Float>(0.5, 0.50),
                          SIMD2<Float>(0.5, 0.60)],
            lineHalfSizes: [SIMD2<Float>(0.08, 0.01),
                            SIMD2<Float>(0.02, 0.02),
                            SIMD2<Float>(0.06, 0.01)],
            paddingUV: 0.01)

        XCTAssertEqual(plate?.minU ?? 0, 0.41, accuracy: 1e-5)
        XCTAssertEqual(plate?.maxU ?? 0, 0.59, accuracy: 1e-5)
        XCTAssertEqual(plate?.minV ?? 0, 0.38, accuracy: 1e-5)
        XCTAssertEqual(plate?.maxV ?? 0, 0.62, accuracy: 1e-5)
    }

    func testStampPlateIsNilWithoutLines() {
        XCTAssertNil(DebugTileGridMath.makeStampPlate(lineAnchors: [],
                                                       lineHalfSizes: [],
                                                       paddingUV: 0.01))
    }

    func testStampPlateIsNilWhenLineCountsDisagree() {
        XCTAssertNil(DebugTileGridMath.makeStampPlate(lineAnchors: [SIMD2<Float>(0.5, 0.5)],
                                                       lineHalfSizes: [],
                                                       paddingUV: 0.01))
    }

    func testStampPlateIgnoresNonFiniteLines() {
        let plate = DebugTileGridMath.makeStampPlate(
            lineAnchors: [SIMD2<Float>(0.5, 0.5), SIMD2<Float>(.nan, 0.5)],
            lineHalfSizes: [SIMD2<Float>(0.1, 0.02), SIMD2<Float>(0.1, 0.02)],
            paddingUV: 0)

        XCTAssertEqual(plate?.minU ?? 0, 0.4, accuracy: 1e-5)
        XCTAssertEqual(plate?.maxU ?? 0, 0.6, accuracy: 1e-5)
    }

    func testDensityClampSnapsToTheNearestOfferedValue() {
        XCTAssertEqual(DebugTileGridDensity.clamp(6), 6)
        XCTAssertEqual(DebugTileGridDensity.clamp(0), 2)
        XCTAssertEqual(DebugTileGridDensity.clamp(-4), 2)
        XCTAssertEqual(DebugTileGridDensity.clamp(5), 4)
        XCTAssertEqual(DebugTileGridDensity.clamp(7), 6)
        XCTAssertEqual(DebugTileGridDensity.clamp(64), 8)
    }
}
