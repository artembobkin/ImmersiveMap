// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// What a tile draws of its buildings when the frame leaves some out: the
/// runs of the extruded indices between the hidden buildings' ranges.
final class TileBuildingRangeTests: XCTestCase {
    private func range(_ featureID: UInt64, _ start: UInt32, _ count: UInt32) -> TileBuildingRange {
        TileBuildingRange(featureID: featureID, indexStart: start, indexCount: count)
    }

    /// The layout is what the prepared tile stores, byte for byte.
    func testARangeIsSixteenBytes() {
        XCTAssertEqual(MemoryLayout<TileBuildingRange>.stride, 16)
        XCTAssertEqual(MemoryLayout<TileBuildingRange>.offset(of: \.indexStart), 8)
        XCTAssertEqual(MemoryLayout<TileBuildingRange>.offset(of: \.indexCount), 12)
    }

    func testNothingHiddenDrawsTheTileWhole() {
        let ranges = [range(1, 0, 30), range(2, 30, 60)]

        XCTAssertNil(TileBuildingRange.indexRuns(of: ranges, indexCount: 90, hiding: []))
        XCTAssertNil(TileBuildingRange.indexRuns(of: ranges, indexCount: 90, hiding: [7]),
                     "a building of another tile changes nothing here")
        XCTAssertNil(TileBuildingRange.indexRuns(of: [], indexCount: 90, hiding: [1]))
    }

    func testAHiddenBuildingIsCutOutOfTheDraw() {
        let ranges = [range(1, 0, 30), range(2, 30, 60), range(3, 90, 30)]

        XCTAssertEqual(TileBuildingRange.indexRuns(of: ranges, indexCount: 120, hiding: [2]), [0..<30, 90..<120])
        XCTAssertEqual(TileBuildingRange.indexRuns(of: ranges, indexCount: 120, hiding: [1]), [30..<120])
        XCTAssertEqual(TileBuildingRange.indexRuns(of: ranges, indexCount: 120, hiding: [3]), [0..<90])
        XCTAssertEqual(TileBuildingRange.indexRuns(of: ranges, indexCount: 120, hiding: [1, 2, 3]), [])
    }

    /// A building of several volumes under one id (a multipolygon) has a
    /// range for each, apart in the indices: its id takes all of them out.
    func testABuildingOfSeveralVolumesGoesWhole() {
        let ranges = [range(5, 0, 30), range(5, 60, 30), range(9, 30, 30)]

        XCTAssertEqual(TileBuildingRange.indexRuns(of: ranges, indexCount: 90, hiding: [5]), [30..<60])
    }

    /// A model lists its building's outline and parts one by one, and the
    /// tile cuts exactly the ids listed: a part left out stays.
    func testOnlyTheListedIdsAreCut() {
        // An outline 5 and its parts 11 and 12, as three buildings.
        let ranges = [range(5, 0, 30), range(11, 30, 30), range(12, 60, 30)]

        XCTAssertEqual(TileBuildingRange.indexRuns(of: ranges, indexCount: 90, hiding: [5]), [30..<90])
        XCTAssertEqual(TileBuildingRange.indexRuns(of: ranges, indexCount: 90, hiding: [5, 11, 12]), [])
    }

    /// Indices no range covers (a volume without an id) always draw.
    func testIndicesOutsideEveryRangeStay() {
        let ranges = [range(4, 30, 30)]

        XCTAssertEqual(TileBuildingRange.indexRuns(of: ranges, indexCount: 100, hiding: [4]), [0..<30, 60..<100])
    }
}
