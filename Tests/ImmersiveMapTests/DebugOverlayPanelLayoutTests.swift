// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class DebugOverlayPanelLayoutTests: XCTestCase {
    func testBodyHeightIsCappedToAvailablePanelSpace() {
        let height = DebugOverlayPanelLayout.visibleBodyHeight(preferredBodyHeight: 1400,
                                                              viewportHeight: 844,
                                                              panelMinY: 20,
                                                              chromeHeight: 220,
                                                              minimumBodyHeight: 48)

        XCTAssertEqual(height, 604)
    }

    func testBodyHeightKeepsPreferredHeightWhenItFits() {
        let height = DebugOverlayPanelLayout.visibleBodyHeight(preferredBodyHeight: 320,
                                                              viewportHeight: 844,
                                                              panelMinY: 20,
                                                              chromeHeight: 220,
                                                              minimumBodyHeight: 48)

        XCTAssertEqual(height, 320)
    }

    func testRowDrawRectUsesBoundsWidthInsteadOfDirtyRectWidth() {
        let rowRect = DebugOverlayPanelLayout.rowDrawRect(bounds: CGRect(x: 0, y: 0, width: 360, height: 120),
                                                          dirtyRect: CGRect(x: 0, y: 0, width: 24, height: 120),
                                                          rowTop: 32,
                                                          rowHeight: 28)

        XCTAssertEqual(rowRect, CGRect(x: 0, y: 32, width: 360, height: 28))
    }
}
