// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Перспективный дистанционный LOD препроцессора с крутизной 1.5 и капом z-4:
/// 0-2 exact, 3 → z-1, 4-5 → z-2, 6-8 → z-3, 9+ → z-4.
final class VisibleTilesPreprocessorDistanceLodTests: XCTestCase {
    private let preprocessor = VisibleTilesPreprocessor()

    func testDistanceLadderCoarsensByDoublingDistance() {
        let casesByDistance: [(distance: Int, expectedZoom: Int)] = [
            (0, 6), (2, 6),
            (3, 5),
            (4, 4), (5, 4),
            (6, 3), (8, 3),
            (9, 2), (15, 2),
            (16, 2), (40, 2)
        ]

        for testCase in casesByDistance {
            let tile = VisibleTile(x: testCase.distance, y: 10, z: 6)
            let output = preprocessor.preprocess(visibleTiles: [tile],
                                                 center: Center(tileX: 0.0, tileY: 10.0),
                                                 renderSurfaceMode: .flat,
                                                 transition: 1)

            XCTAssertEqual(output.count, 1, "distance \(testCase.distance)")
            XCTAssertEqual(output.first?.z, testCase.expectedZoom,
                           "distance \(testCase.distance): ожидался z\(testCase.expectedZoom), получен z\(String(describing: output.first?.z))")
        }
    }

    func testTilesBeyondMaxVisibleDistanceAreDropped() {
        let tile = VisibleTile(x: 41, y: 10, z: 6)

        let output = preprocessor.preprocess(visibleTiles: [tile],
                                             center: Center(tileX: 0.0, tileY: 10.0),
                                             renderSurfaceMode: .flat,
                                             transition: 1)

        XCTAssertTrue(output.isEmpty)
    }

    func testFarFieldCollapsesManyTilesIntoFewCoarseParents() {
        // Дальняя полоса 7x5 = 35 тайлов на дистанции 9-15: лесенка сводит их
        // к горстке z3-родителей без перекрытий.
        var farBand: [VisibleTile] = []
        for x in 9...15 {
            for y in 8...12 {
                farBand.append(VisibleTile(x: x, y: y, z: 6))
            }
        }

        let output = preprocessor.preprocess(visibleTiles: farBand,
                                             center: Center(tileX: 0.0, tileY: 10.0),
                                             renderSurfaceMode: .flat,
                                             transition: 1)

        XCTAssertFalse(output.isEmpty)
        XCTAssertLessThanOrEqual(output.count, 6,
                                 "Дальняя полоса должна схлопнуться в несколько грубых тайлов, получено \(output.count)")
        XCTAssertTrue(output.allSatisfy { $0.z <= 3 },
                      "Ожидались только грубые родители, получено: \(output.map(\.z))")
    }
}
