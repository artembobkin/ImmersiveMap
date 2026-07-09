// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PreprocessedVisibleTilesHasherTests: XCTestCase {
    func testHashChangesWhenDemandedFallbackParentBecomesReady() {
        let targetTile = Tile(x: 38, y: 19, z: 6)
        let fallbackParentTile = Tile(x: 9, y: 4, z: 4)
        let target = VisibleTile(tile: targetTile)

        let missingFallbackHash = PreprocessedVisibleTilesHasher.computePreprocessedVisibleTilesHash(
            preprocessedVisibleTiles: [target],
            demandedSourceTiles: [targetTile, fallbackParentTile],
            isSourceReady: { _ in false }
        )
        let readyFallbackHash = PreprocessedVisibleTilesHasher.computePreprocessedVisibleTilesHash(
            preprocessedVisibleTiles: [target],
            demandedSourceTiles: [targetTile, fallbackParentTile],
            isSourceReady: { source in source == fallbackParentTile }
        )

        XCTAssertNotEqual(missingFallbackHash, readyFallbackHash)
    }
}
