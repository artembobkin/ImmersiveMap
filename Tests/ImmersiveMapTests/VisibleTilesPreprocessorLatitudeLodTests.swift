// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The preprocessor's latitude LOD: on the globe, near-polar mercator tiles are
/// replaced with coarser parents (a tile near a pole is `cos(latitude)` times
/// smaller than an equatorial one); on the flat map and during the transition
/// to it there is no replacement.
final class VisibleTilesPreprocessorLatitudeLodTests: XCTestCase {
    private let preprocessor = VisibleTilesPreprocessor()

    func testGlobePolarRowIsCoarsenedOnSphere() {
        // Row z4/y0: the edge nearest the equator is at latitude ~82.7°,
        // log2(1/cos) ≈ 2.97 → a drop of 2 levels.
        let polarRow = (0..<16).map { VisibleTile(x: $0, y: 0, z: 4) }
        let center = Center(tileX: 8.0, tileY: 0.5)

        let output = preprocessor.preprocess(visibleTiles: polarRow,
                                             center: center,
                                             renderSurfaceMode: .spherical,
                                             transition: 0)

        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.allSatisfy { $0.z == 2 },
                      "Expected z2 parents, got: \(output.map(\.z))")
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
        // A full column from pole to pole: the drop-zone boundaries must not
        // produce overlapping coverage.
        let column = (0..<16).map { VisibleTile(x: 8, y: $0, z: 4) }
        let center = Center(tileX: 8.5, tileY: 8.0)

        let output = preprocessor.preprocess(visibleTiles: column,
                                             center: center,
                                             renderSurfaceMode: .spherical,
                                             transition: 0)

        for (index, lhs) in output.enumerated() {
            for rhs in output[(index + 1)...] {
                XCTAssertFalse(tilesOverlap(lhs, rhs), "Overlap: \(lhs) and \(rhs)")
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
