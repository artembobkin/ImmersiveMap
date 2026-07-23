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
}
