// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class DebugOverlayControlStateTests: XCTestCase {
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

    func testSetLabelBoundsEnabledUpdatesSnapshotIndependently() {
        let controls = DebugOverlayControlState()

        controls.setBaseLabelBoundsEnabled(true)
        XCTAssertTrue(controls.snapshot().baseLabelBoundsEnabled)
        XCTAssertFalse(controls.snapshot().roadLabelBoundsEnabled)

        controls.setBaseLabelBoundsEnabled(false)
        controls.setRoadLabelBoundsEnabled(true)
        XCTAssertFalse(controls.snapshot().baseLabelBoundsEnabled)
        XCTAssertTrue(controls.snapshot().roadLabelBoundsEnabled)
    }

    func testEitherLabelBoundsToggleEncodesOverlayPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true

        let baseControls = DebugOverlayControlState()
        baseControls.setBaseLabelBoundsEnabled(true)
        XCTAssertTrue(RenderDebugOverlayPolicy.shouldEncode(settings,
                                                            controls: baseControls.snapshot()))

        let roadControls = DebugOverlayControlState()
        roadControls.setRoadLabelBoundsEnabled(true)
        XCTAssertTrue(RenderDebugOverlayPolicy.shouldEncode(settings,
                                                            controls: roadControls.snapshot()))
    }

    func testTileGridStartsOffAtTheStandardDensity() {
        let snapshot = DebugOverlayControlState().snapshot()

        XCTAssertFalse(snapshot.tileGridEnabled)
        XCTAssertEqual(snapshot.tileGridDensity, DebugTileGridDensity.standard)
    }

    func testSetTileGridEnabledUpdatesSnapshotIndependently() {
        let controls = DebugOverlayControlState()

        controls.setTileGridEnabled(true)

        XCTAssertTrue(controls.snapshot().tileGridEnabled)
        XCTAssertFalse(controls.snapshot().tileLayersEnabled)
    }

    func testTileGridDebugRequiresMetalDebugPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let controls = DebugOverlayControlState()

        controls.setTileGridEnabled(true)

        XCTAssertTrue(RenderDebugOverlayPolicy.shouldEncode(settings,
                                                            controls: controls.snapshot()))
    }

    func testTileGridDensityIsClampedToAnOfferedValue() {
        let controls = DebugOverlayControlState()

        controls.setTileGridDensity(8)
        XCTAssertEqual(controls.snapshot().tileGridDensity, 8)

        controls.setTileGridDensity(1000)
        XCTAssertEqual(controls.snapshot().tileGridDensity, 8)

        controls.setTileGridDensity(0)
        XCTAssertEqual(controls.snapshot().tileGridDensity, 2)
    }
}
