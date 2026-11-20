// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

final class ImmersiveMapRenderedFrameSettleTests: XCTestCase {
    private func frame(visible: Int = 12, tiles: Int = 0, terrain: Int = 0, models: Int = 0, layers: Int = 0)
        -> ImmersiveMapRenderedFrame {
        ImmersiveMapRenderedFrame(frameIndex: 1, cpuDuration: 0.002, targetPresentationTimestamp: 0,
                                  visibleTileCount: visible, pendingTileCount: tiles,
                                  pendingTerrainTileCount: terrain, pendingSceneModelMeshCount: models,
                                  pendingLayerMeshCount: layers)
    }

    func testNothingPendingMeansNoPendingWork() {
        XCTAssertFalse(frame().hasPendingWork)
    }

    func testEachKindOfPendingWorkCounts() {
        XCTAssertTrue(frame(tiles: 1).hasPendingWork)
        XCTAssertTrue(frame(terrain: 1).hasPendingWork)
        XCTAssertTrue(frame(models: 1).hasPendingWork)
        XCTAssertTrue(frame(layers: 1).hasPendingWork)
    }

    func testTheOriginalInitStillWorks() {
        let legacy = ImmersiveMapRenderedFrame(frameIndex: 3, cpuDuration: 0.001, targetPresentationTimestamp: 1)
        XCTAssertEqual(legacy.visibleTileCount, 0)
        XCTAssertFalse(legacy.hasPendingWork)
    }
}
