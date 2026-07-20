// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Широтный LOD препроцессора: на глобусе приполярные меркаторные тайлы
/// подменяются более грубыми родителями (тайл у полюса в `cos(широты)` раз
/// меньше экваторного), на плоской карте и при переходе к ней подмены нет.
final class VisibleTilesPreprocessorLatitudeLodTests: XCTestCase {
    private let preprocessor = VisibleTilesPreprocessor()

    func testGlobePolarRowIsCoarsenedOnSphere() {
        // Ряд z4/y0: ближайший к экватору край на широте ~82.7°,
        // log2(1/cos) ≈ 2.97 → понижение на 2 уровня.
        let polarRow = (0..<16).map { VisibleTile(x: $0, y: 0, z: 4) }
        let center = Center(tileX: 8.0, tileY: 0.5)

        let output = preprocessor.preprocess(visibleTiles: polarRow,
                                             center: center,
                                             renderSurfaceMode: .spherical,
                                             transition: 0)

        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.allSatisfy { $0.z == 2 },
                      "Ожидались родители z2, получено: \(output.map(\.z))")
    }

    func testGlobeEquatorRowStaysExactOnSphere() {
        let equatorRow = (6..<10).map { VisibleTile(x: $0, y: 7, z: 4) }
        let center = Center(tileX: 8.0, tileY: 7.5)

        let output = preprocessor.preprocess(visibleTiles: equatorRow,
                                             center: center,
                                             renderSurfaceMode: .spherical,
                                             transition: 0)

        XCTAssertEqual(Set(output), Set(equatorRow))
    }

    func testPolarRowStaysExactOnFlatSurface() {
        let polarRow = (6..<10).map { VisibleTile(x: $0, y: 0, z: 4) }
        let center = Center(tileX: 8.0, tileY: 0.5)

        let output = preprocessor.preprocess(visibleTiles: polarRow,
                                             center: center,
                                             renderSurfaceMode: .flat,
                                             transition: 1)

        XCTAssertEqual(Set(output), Set(polarRow))
    }

    func testPolarRowStaysExactWhenTransitionReachesFlatPhase() {
        let polarRow = (6..<10).map { VisibleTile(x: $0, y: 0, z: 4) }
        let center = Center(tileX: 8.0, tileY: 0.5)

        let output = preprocessor.preprocess(visibleTiles: polarRow,
                                             center: center,
                                             renderSurfaceMode: .spherical,
                                             transition: 1)

        XCTAssertEqual(Set(output), Set(polarRow))
    }

    func testMixedLatitudeCoverageHasNoOverlap() {
        // Полный столбец от полюса до полюса: границы зон понижения не должны
        // давать пересекающееся покрытие.
        let column = (0..<16).map { VisibleTile(x: 8, y: $0, z: 4) }
        let center = Center(tileX: 8.5, tileY: 8.0)

        let output = preprocessor.preprocess(visibleTiles: column,
                                             center: center,
                                             renderSurfaceMode: .spherical,
                                             transition: 0)

        for (index, lhs) in output.enumerated() {
            for rhs in output[(index + 1)...] {
                XCTAssertFalse(tilesOverlap(lhs, rhs), "Пересечение: \(lhs) и \(rhs)")
            }
        }
    }

    private func tilesOverlap(_ lhs: VisibleTile, _ rhs: VisibleTile) -> Bool {
        guard lhs.loop == rhs.loop else {
            return false
        }
        let (coarse, fine) = lhs.z <= rhs.z ? (lhs, rhs) : (rhs, lhs)
        let shift = fine.z - coarse.z
        return (fine.x >> shift) == coarse.x && (fine.y >> shift) == coarse.y
    }
}
