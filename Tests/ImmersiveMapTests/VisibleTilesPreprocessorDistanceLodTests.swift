// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Перспективный дистанционный LOD препроцессора. Сфера (крутизна 1.5):
/// 0-2 exact, 3 → z-1, 4-5 → z-2, 6-8 → z-3, 9+ → z-4, за дистанцией 15
/// кламп предпочтения к зуму подложки z3. Плоскость (крутизна 3.0): 3 → z-2,
/// 4 → z-3, 5+ → z-4, за дистанцией 10 кольцо выбрасывается целиком: его
/// область закрашена z3-подложкой горизонта.
final class VisibleTilesPreprocessorDistanceLodTests: XCTestCase {
    private let preprocessor = VisibleTilesPreprocessor()

    func testFlatDistanceLadderCoarsensSteeply() {
        let casesByDistance: [(distance: Int, expectedZoom: Int)] = [
            (0, 6), (2, 6),
            (3, 4),
            (4, 3),
            (5, 2), (8, 2), (10, 2)
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

    /// В плоском режиме за радиусом 10 кольцо не размещается вовсе: его
    /// область закрашена сплошной z3-подложкой горизонта, а размещение
    /// z3-предка либо дублировало бы подложку, либо эскалировало бы к мелким
    /// векторным тайлам поверх ближнего покрытия.
    func testFlatFarRingIsHandedToBackdrop() {
        let cases: [(x: Int, expectedZooms: [Int], note: String)] = [
            (8, [5], "внутри порога работает лесенка (z-4 на дистанции 8)"),
            (10, [5], "дистанция 10 ещё на лесенке"),
            (11, [], "за порогом 10 тайл отдан подложке"),
            (20, [], "глубокая даль отдана подложке")
        ]

        for testCase in cases {
            let tile = VisibleTile(x: testCase.x, y: 10, z: 9)
            let output = preprocessor.preprocess(visibleTiles: [tile],
                                                 center: Center(tileX: 0.0, tileY: 10.0),
                                                 renderSurfaceMode: .flat,
                                                 transition: 1)

            XCTAssertEqual(output.map(\.z), testCase.expectedZooms, testCase.note)
        }
    }

    /// Сценарий наклонной камеры: ближний блок точных тайлов плюс дальнее
    /// кольцо. Раньше z3-предок дальнего тайла перекрывался с ближним
    /// покрытием, и жадный выбор эскалировал кольцо до свободных предков
    /// z4-z8: даль превращалась в десятки настоящих векторных тайлов. Теперь
    /// кольцо выбрасывается, в выводе остаётся только ближнее покрытие.
    func testFlatFarRingDoesNotEscalateOverNearCoverage() {
        var nearBlock: [VisibleTile] = []
        for x in 0...2 {
            for y in 9...11 {
                nearBlock.append(VisibleTile(x: x, y: y, z: 9))
            }
        }
        var farRing: [VisibleTile] = []
        for x in 12...14 {
            for y in 9...11 {
                farRing.append(VisibleTile(x: x, y: y, z: 9))
            }
        }

        let output = preprocessor.preprocess(visibleTiles: nearBlock + farRing,
                                             center: Center(tileX: 0.0, tileY: 10.0),
                                             renderSurfaceMode: .flat,
                                             transition: 1)

        XCTAssertEqual(Set(output), Set(nearBlock),
                       "Ожидалось только ближнее точное покрытие, получено: \(output.map { "z\($0.z)/\($0.x)/\($0.y)" })")
    }

    /// Без подложки кольцо выбрасывать нельзя: на целевых зумах не глубже z3
    /// подложка не собирается (`TileCulling` требует targetZoom > z3), и
    /// врапнутая мировая копия за порогом осталась бы дырой.
    func testFlatFarRingWithoutBackdropKeepsCoverage() {
        let wrappedTile = VisibleTile(x: 7, y: 4, z: 3, loop: 1)

        let output = preprocessor.preprocess(visibleTiles: [wrappedTile],
                                             center: Center(tileX: 0.0, tileY: 4.0),
                                             renderSurfaceMode: .flat,
                                             transition: 1)

        XCTAssertEqual(output, [VisibleTile(x: 0, y: 0, z: 0, loop: 1)],
                       "Дальний тайл врапнутой копии обязан остаться покрытием (лесенка до z0)")
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
        // Полоса 7x5 = 35 тайлов на дистанциях 9-15: часть до порога (9-10)
        // схлопывается лесенкой в горстку грубых родителей, часть за порогом
        // (11-15) отдаётся подложке и в вывод не попадает.
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
