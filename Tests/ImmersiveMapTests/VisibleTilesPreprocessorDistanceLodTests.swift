// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Perspective distance LOD of the preprocessor. Sphere (steepness 1.5):
/// 0-2 exact, 3 → z-1, 4-5 → z-2, 6-8 → z-3, 9+ → z-4, beyond distance 15
/// the preference clamps to the z3 backdrop zoom. Flat (steepness 3.0): 3 → z-2,
/// 4 → z-3, 5+ → z-4, beyond distance 10 the ring is dropped entirely: its
/// area is painted by the z3 horizon backdrop.
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

    /// The spherical ladder stays at steepness 1.5: the globe visuals were
    /// tuned separately and the flat tightening does not touch them.
    /// Row y=31 tiles sit next to the equator, so the latitude drop is zero.
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

    /// In flat mode, beyond radius 10 the ring is not placed at all: its area
    /// is painted by the solid z3 horizon backdrop, and placing a z3 ancestor
    /// would either duplicate the backdrop or escalate to fine vector tiles
    /// on top of the near coverage.
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

    /// Tilted camera scenario: a near block of exact tiles plus a far ring.
    /// Previously the far tile's z3 ancestor overlapped the near coverage,
    /// and the greedy selection escalated the ring to free ancestors
    /// z4-z8: the distance turned into dozens of real vector tiles. Now
    /// the ring is dropped and only the near coverage remains in the output.
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

    /// Without a backdrop the ring must not be dropped: at target zooms no
    /// deeper than z3 the backdrop is not built (`TileCulling` requires
    /// targetZoom > z3), and a wrapped world copy beyond the threshold would be left as a hole.
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
        // A 7x5 band = 35 tiles at distances 9-15: the part before the threshold (9-10)
        // collapses via the ladder into a handful of coarse parents, the part beyond
        // the threshold (11-15) is handed to the backdrop and never reaches the output.
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
