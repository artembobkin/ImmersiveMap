// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// On the relief a road label's path is cut where the road's ribbon is, at
/// the grid's crossings, so the placer raises it point by point with the
/// road and the name follows the drawn road over the slopes.
final class RoadLabelReliefPathTests: XCTestCase {
    private static func point(_ x: Float, _ y: Float) -> TilePointInput {
        TilePointInput(uv: SIMD2(x, y), tile: SIMD3(1, 2, 3))
    }

    /// A segment takes a point at every grid line it crosses, in its own
    /// order, and keeps its ends.
    func testAPathIsCutAtEveryGridCrossing() {
        let cut = RoadLabelCache.cutAtGrid([Self.point(0.1, 0.1), Self.point(0.9, 0.6)], stepUV: 0.25)
        let crossed = cut.points.map(\.uv)
        XCTAssertEqual(crossed.first, SIMD2(0.1, 0.1))
        XCTAssertEqual(crossed.last, SIMD2(0.9, 0.6))
        // x = 0.25, 0.5, 0.75 and y = 0.25, 0.5: five crossings, in order.
        XCTAssertEqual(crossed.count, 7)
        for (earlier, later) in zip(crossed, crossed.dropFirst()) {
            XCTAssertLessThan(earlier.x, later.x, "Along the segment")
        }
        XCTAssertEqual(cut.points[1].tile, SIMD3(1, 2, 3), "A cut point keeps its tile")
    }

    /// An anchor moves onto the cut segment its place falls in, and a path
    /// that crosses no line is left whole.
    func testAnAnchorLandsOnItsCutSegment() {
        let cut = RoadLabelCache.cutAtGrid([Self.point(0.1, 0.5), Self.point(0.9, 0.5), Self.point(0.9, 0.55)], stepUV: 0.25)
        // The first segment cut at x = 0.25, 0.5 and 0.75, the second (y up
        // from 0.5, a grid line, to 0.55) not at all.
        XCTAssertEqual(cut.points.count, 6)
        XCTAssertEqual(cut.firstSegments, [0, 4])
        let anchor = RoadLabelAnchor(pathIndex: 0, segmentIndex: 0, t: 0.6, anchorOrdinal: 0)
        XCTAssertEqual(cut.segment(of: anchor), 2, "x 0.58 lies between 0.5 and 0.75")
        XCTAssertEqual(cut.segment(of: RoadLabelAnchor(pathIndex: 0, segmentIndex: 1, t: 0.5, anchorOrdinal: 0)), 4)
        let whole = RoadLabelCache.cutAtGrid([Self.point(0.3, 0.3), Self.point(0.4, 0.4)], stepUV: 0.25)
        XCTAssertEqual(whole.points.count, 2)
        XCTAssertEqual(whole.segment(of: RoadLabelAnchor(pathIndex: 0, segmentIndex: 0, t: 0.5, anchorOrdinal: 0)), 0)
    }
}
