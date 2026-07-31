// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class TileDemandPriorityMathTests: XCTestCase {
    func testFlatSortPutsTilesNearCameraCenterFirst() {
        // Center in the middle of tile (2, 2) at z2: 4x4 world, center (0.625, 0.625).
        let center = SIMD2<Double>(0.625, 0.625)
        let nearTile = VisibleTile(x: 2, y: 2, z: 2)
        let sideTile = VisibleTile(x: 1, y: 2, z: 2)
        let farTile = VisibleTile(x: 0, y: 0, z: 2)

        let sorted = TileDemandPriorityMath.sortedByCameraProximity([farTile, sideTile, nearTile],
                                                                    centerWorldMercator: center,
                                                                    renderSurfaceMode: .flat)

        XCTAssertEqual(sorted, [nearTile, sideTile, farTile])
    }

    func testSortComparesMixedZoomTargetsInWorldUnits() {
        // The far coarse target (z3) is geographically farther from the center
        // than the detailed near ones (z5): the normalized metric must not give
        // the coarse tile a head start due to its larger size.
        let center = SIMD2<Double>(0.5, 0.5)
        let nearDetailed = VisibleTile(x: 16, y: 16, z: 5)
        let nearbyDetailed = VisibleTile(x: 15, y: 16, z: 5)
        let farCoarse = VisibleTile(x: 1, y: 4, z: 3)

        let sorted = TileDemandPriorityMath.sortedByCameraProximity([farCoarse, nearbyDetailed, nearDetailed],
                                                                    centerWorldMercator: center,
                                                                    renderSurfaceMode: .flat)

        XCTAssertEqual(sorted.last, farCoarse)
        XCTAssertEqual(Set(sorted.prefix(2)), Set([nearDetailed, nearbyDetailed]))
    }

    func testFlatSortRespectsLoopOffset() {
        // Center near the world's right edge (x=0.9): the loop 1 copy of tile x=0
        // (world position 1.0625) is closer than its loop 0 copy (0.0625).
        let center = SIMD2<Double>(0.9, 0.5)
        let wrappedCopy = VisibleTile(x: 0, y: 2, z: 3, loop: 1)
        let baseCopy = VisibleTile(x: 0, y: 2, z: 3, loop: 0)

        let sorted = TileDemandPriorityMath.sortedByCameraProximity([baseCopy, wrappedCopy],
                                                                    centerWorldMercator: center,
                                                                    renderSurfaceMode: .flat)

        XCTAssertEqual(sorted, [wrappedCopy, baseCopy])
    }

    func testSphericalSortWrapsAroundAntimeridian() {
        // Center near the antimeridian (x=0.98): tile x=0 at z3 (center 0.0625)
        // is closer through the wrap (0.1) than a tile in mid-world (0.5, distance 0.42).
        let center = SIMD2<Double>(0.98, 0.5)
        let acrossAntimeridian = VisibleTile(x: 0, y: 4, z: 3)
        let midWorld = VisibleTile(x: 4, y: 4, z: 3)

        let sorted = TileDemandPriorityMath.sortedByCameraProximity([midWorld, acrossAntimeridian],
                                                                    centerWorldMercator: center,
                                                                    renderSurfaceMode: .spherical)

        XCTAssertEqual(sorted, [acrossAntimeridian, midWorld])
    }

    func testSortIsDeterministicForEqualDistances() {
        // Four tiles symmetric around the center: equal distances, the order
        // must be stable (loop/x/y) from call to call.
        let center = SIMD2<Double>(0.5, 0.5)
        let tiles = [
            VisibleTile(x: 4, y: 3, z: 3),
            VisibleTile(x: 3, y: 4, z: 3),
            VisibleTile(x: 3, y: 3, z: 3),
            VisibleTile(x: 4, y: 4, z: 3)
        ]

        let sortedOnce = TileDemandPriorityMath.sortedByCameraProximity(tiles,
                                                                        centerWorldMercator: center,
                                                                        renderSurfaceMode: .flat)
        let sortedTwice = TileDemandPriorityMath.sortedByCameraProximity(tiles.reversed(),
                                                                         centerWorldMercator: center,
                                                                         renderSurfaceMode: .flat)

        XCTAssertEqual(sortedOnce, sortedTwice)
    }
}
