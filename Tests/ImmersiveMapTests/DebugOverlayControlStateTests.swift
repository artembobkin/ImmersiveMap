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

    func testSetLabelBoundsEnabledUpdatesSnapshot() {
        let controls = DebugOverlayControlState()

        controls.setLabelBoundsEnabled(true)

        XCTAssertTrue(controls.snapshot().labelBoundsEnabled)
    }

    func testLabelBoundsDebugEncodesOverlayPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let controls = DebugOverlayControlState()

        controls.setLabelBoundsEnabled(true)

        XCTAssertTrue(RenderDebugOverlayPolicy.shouldEncode(settings,
                                                            controls: controls.snapshot()))
    }
}
