// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileDemandSourcePlannerTests: XCTestCase {
    func testDemandedSourceTilesIncludeParentFallbacks() {
        let target = VisibleTile(tile: Tile(x: 38, y: 19, z: 6))

        let demanded = TileDemandSourcePlanner.makeDemandedSourceTiles(
            targets: [target],
            parentFallbackDepth: 2
        )

        XCTAssertEqual(demanded, [
            Tile(x: 38, y: 19, z: 6),
            Tile(x: 19, y: 9, z: 5),
            Tile(x: 9, y: 4, z: 4)
        ])
    }

    func testDemandedSourceTilesDeduplicateSharedParents() {
        let targets = [
            VisibleTile(tile: Tile(x: 38, y: 19, z: 6)),
            VisibleTile(tile: Tile(x: 39, y: 19, z: 6))
        ]

        let demanded = TileDemandSourcePlanner.makeDemandedSourceTiles(
            targets: targets,
            parentFallbackDepth: 2
        )

        XCTAssertEqual(demanded, [
            Tile(x: 38, y: 19, z: 6),
            Tile(x: 19, y: 9, z: 5),
            Tile(x: 9, y: 4, z: 4),
            Tile(x: 39, y: 19, z: 6)
        ])
    }
}
