// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class DebugOverlayControlStateTests: XCTestCase {
    func testDefaultSnapshotEnablesTerrain() {
        let controls = DebugOverlayControlState()

        XCTAssertTrue(controls.snapshot().terrainEnabled)
    }

    func testSetTerrainEnabledUpdatesSnapshot() {
        let controls = DebugOverlayControlState()

        controls.setTerrainEnabled(false)

        XCTAssertFalse(controls.snapshot().terrainEnabled)
    }

    func testSetTerrainEnabledDoesNotChangeOtherControls() {
        let controls = DebugOverlayControlState()
        controls.setAxesEnabled(true)
        controls.setTileLayersEnabled(false)
        controls.setWireframeEnabled(true)

        controls.setTerrainEnabled(false)

        let snapshot = controls.snapshot()
        XCTAssertTrue(snapshot.axesEnabled)
        XCTAssertFalse(snapshot.tileLayersEnabled)
        XCTAssertTrue(snapshot.wireframeEnabled)
        XCTAssertFalse(snapshot.terrainEnabled)
    }

    func testSetRoadLabelTilesEnabledUpdatesSnapshot() {
        let controls = DebugOverlayControlState()

        controls.setRoadLabelTilesEnabled(true)

        XCTAssertTrue(controls.snapshot().roadLabelTilesEnabled)
    }

    func testRoadLabelTilesDebugRequiresMetalDebugPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let controls = DebugOverlayControlState()

        controls.setRoadLabelTilesEnabled(true)

        XCTAssertTrue(RenderDebugOverlayPolicy.shouldEncode(settings,
                                                            controls: controls.snapshot()))
    }

    func testTerrainOnlyToggleDoesNotRequireMetalDebugPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let controls = DebugOverlayControlState()

        controls.setTerrainEnabled(false)

        XCTAssertFalse(RenderDebugOverlayPolicy.shouldEncode(settings,
                                                             controls: controls.snapshot()))
    }
}
