// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class TileDemandPriorityMathTests: XCTestCase {
    func testFlatSortPutsTilesNearCameraCenterFirst() {
        // Центр в середине тайла (2, 2) на z2: мир 4x4, центр (0.625, 0.625).
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
        // Дальний грубый таргет (z3) географически дальше от центра, чем
        // детальные ближние (z5): нормализованная метрика не должна давать
        // грубому тайлу фору за счёт большего размера.
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
        // Центр у правого края мира (x=0.9): копия тайла x=0 из loop 1
        // (мировая позиция 1.0625) ближе, чем его копия из loop 0 (0.0625).
        let center = SIMD2<Double>(0.9, 0.5)
        let wrappedCopy = VisibleTile(x: 0, y: 2, z: 3, loop: 1)
        let baseCopy = VisibleTile(x: 0, y: 2, z: 3, loop: 0)

        let sorted = TileDemandPriorityMath.sortedByCameraProximity([baseCopy, wrappedCopy],
                                                                    centerWorldMercator: center,
                                                                    renderSurfaceMode: .flat)

        XCTAssertEqual(sorted, [wrappedCopy, baseCopy])
    }

    func testSphericalSortWrapsAroundAntimeridian() {
        // Центр у антимеридиана (x=0.98): тайл x=0 на z3 (центр 0.0625)
        // через wrap ближе (0.1), чем тайл в середине мира (0.5, дистанция 0.42).
        let center = SIMD2<Double>(0.98, 0.5)
        let acrossAntimeridian = VisibleTile(x: 0, y: 4, z: 3)
        let midWorld = VisibleTile(x: 4, y: 4, z: 3)

        let sorted = TileDemandPriorityMath.sortedByCameraProximity([midWorld, acrossAntimeridian],
                                                                    centerWorldMercator: center,
                                                                    renderSurfaceMode: .spherical)

        XCTAssertEqual(sorted, [acrossAntimeridian, midWorld])
    }

    func testSortIsDeterministicForEqualDistances() {
        // Четыре тайла симметрично вокруг центра: равные дистанции, порядок
        // должен быть стабильным (loop/x/y) от вызова к вызову.
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
