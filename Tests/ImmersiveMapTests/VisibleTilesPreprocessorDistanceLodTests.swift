// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Перспективный дистанционный LOD препроцессора. Сфера (крутизна 1.5):
/// 0-2 exact, 3 → z-1, 4-5 → z-2, 6-8 → z-3, 9+ → z-4. Плоскость (крутизна
/// 3.0): 3 → z-2, 4 → z-3, 5+ → z-4, за дистанцией 10 кламп к зуму подложки z3.
final class VisibleTilesPreprocessorDistanceLodTests: XCTestCase {
    private let preprocessor = VisibleTilesPreprocessor()

    func testFlatDistanceLadderCoarsensSteeply() {
        let casesByDistance: [(distance: Int, expectedZoom: Int)] = [
            (0, 6), (2, 6),
            (3, 4),
            (4, 3),
            (5, 2), (8, 2), (10, 2),
            (40, 2)
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

    /// Сферическая лесенка остаётся на крутизне 1.5: глобусный визуал
    /// подбирался отдельно и плоское ужесточение его не трогает.
    /// Тайлы ряда y=31 прилегают к экватору, широтный drop равен нулю.
    func testSphericalLadderKeepsGentlerSteepness() {
        let casesByDistance: [(distance: Int, expectedZoom: Int)] = [
            (3, 5),
            (8, 3),
            (20, 2)
        ]

        for testCase in casesByDistance {
            let tile = VisibleTile(x: testCase.distance, y: 31, z: 6)
            let output = preprocessor.preprocess(visibleTiles: [tile],
                                                 center: Center(tileX: 0.0, tileY: 31.0),
                                                 renderSurfaceMode: .spherical,
                                                 transition: 0)

            XCTAssertEqual(output.count, 1, "distance \(testCase.distance)")
            XCTAssertEqual(output.first?.z, testCase.expectedZoom,
                           "distance \(testCase.distance): ожидался z\(testCase.expectedZoom), получен z\(String(describing: output.first?.z))")
        }
    }

    /// В плоском режиме за радиусом 10 кольцо падает на абсолютный зум подложки
    /// (z3) независимо от целевого зума: тайлы из пиннинга, дальний план
    /// бесплатный и совпадает по контенту с подложкой горизонта.
    func testFlatFarRingCollapsesToBackdropZoom() {
        let cases: [(x: Int, expectedZoom: Int, note: String)] = [
            (8, 5, "внутри порога работает лесенка (z-4 на дистанции 8)"),
            (10, 5, "дистанция 10 ещё на лесенке"),
            (11, TileCulling.flatBackdropZoomLevel, "за порогом 10 кламп к z3"),
            (20, TileCulling.flatBackdropZoomLevel, "глубокая даль остаётся на z3")
        ]

        for testCase in cases {
            let tile = VisibleTile(x: testCase.x, y: 10, z: 9)
            let output = preprocessor.preprocess(visibleTiles: [tile],
                                                 center: Center(tileX: 0.0, tileY: 10.0),
                                                 renderSurfaceMode: .flat,
                                                 transition: 1)

            XCTAssertEqual(output.map(\.z), [testCase.expectedZoom], testCase.note)
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
        // к горстке грубых родителей без перекрытий.
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
