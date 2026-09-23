// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PMTiles
import PMTilesTestSupport
import XCTest

final class PMTilesTileIDTests: XCTestCase {
    func testZoomZeroIsTileZero() {
        XCTAssertEqual(PMTilesTileID.id(z: 0, x: 0, y: 0), 0)
    }

    func testZoomOneFollowsTheHilbertOrder() {
        XCTAssertEqual(PMTilesTileID.id(z: 1, x: 0, y: 0), 1)
        XCTAssertEqual(PMTilesTileID.id(z: 1, x: 0, y: 1), 2)
        XCTAssertEqual(PMTilesTileID.id(z: 1, x: 1, y: 1), 3)
        XCTAssertEqual(PMTilesTileID.id(z: 1, x: 1, y: 0), 4)
    }

    func testEveryZoomStartsAfterAllLowerZooms() {
        XCTAssertEqual(PMTilesTileID.id(z: 2, x: 0, y: 0), 5)
        XCTAssertEqual(PMTilesTileID.id(z: 3, x: 0, y: 0), 21)
        XCTAssertEqual(PMTilesTileID.id(z: 15, x: 0, y: 0), (UInt64(1) << 30 - 1) / 3)
    }

    /// Values computed by hand from the reference algorithm, so that the
    /// reader and the writer cannot agree on a shared mistake. The tiles on
    /// the right-hand side of the grid are the ones the reflection touches.
    func testTheReflectedQuadrantsMatchTheReferenceAlgorithm() {
        XCTAssertEqual(PMTilesTileID.id(z: 2, x: 3, y: 1), 17)
        XCTAssertEqual(PMTilesTileID.id(z: 2, x: 2, y: 1), 18)
        XCTAssertEqual(PMTilesTileID.id(z: 2, x: 2, y: 0), 19)
        XCTAssertEqual(PMTilesTileID.id(z: 2, x: 3, y: 0), 20)
        XCTAssertEqual(PMTilesTileID.id(z: 3, x: 7, y: 0), 84)
        XCTAssertEqual(PMTilesTileID.id(z: 3, x: 5, y: 2), 76)
        XCTAssertEqual(PMTilesTileID.id(z: 15, x: 32_767, y: 0), 1_431_655_764)
        XCTAssertEqual(PMTilesTileID.id(z: 15, x: 20_000, y: 10_000), 1_279_156_991)
    }

    func testTheReaderAgreesWithTheIndependentWriter() {
        for (z, x, y) in [(2, 3, 1), (5, 17, 9), (12, 2474, 1280), (15, 19_800, 10_200)] {
            XCTAssertEqual(PMTilesTileID.id(z: z, x: x, y: y),
                           PMTilesArchiveWriter.tileID(z: z, x: x, y: y),
                           "z\(z) \(x)/\(y)")
        }
    }

    func testEveryTileOfAZoomHasItsOwnID() throws {
        var seen = Set<UInt64>()
        for x in 0..<8 {
            for y in 0..<8 {
                let id = try XCTUnwrap(PMTilesTileID.id(z: 3, x: x, y: y))
                XCTAssertTrue(seen.insert(id).inserted)
                XCTAssertTrue((21..<85).contains(id))
            }
        }
    }

    func testCoordinatesOutsideTheGridHaveNoID() {
        XCTAssertNil(PMTilesTileID.id(z: 1, x: 2, y: 0))
        XCTAssertNil(PMTilesTileID.id(z: 1, x: 0, y: -1))
        XCTAssertNil(PMTilesTileID.id(z: 32, x: 0, y: 0))
    }
}
