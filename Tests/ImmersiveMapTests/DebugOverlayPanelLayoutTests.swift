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

    func testAtlasPagesUseMultipleColumnsWhenWidthAllows() {
        let layout = DebugOverlayPanelLayout.atlasGridLayout(
            pageCount: 3,
            width: 704,
            pageLabelHeight: 16,
            pageSpacing: 10,
            minimumPageSide: 180,
            maximumPageSide: 260
        )

        XCTAssertEqual(layout.columnCount, 3)
        XCTAssertEqual(layout.height, 244)
        XCTAssertEqual(layout.pageFrames.map(\.pageRect), [
            CGRect(x: 0, y: 16, width: 228, height: 228),
            CGRect(x: 238, y: 16, width: 228, height: 228),
            CGRect(x: 476, y: 16, width: 228, height: 228)
        ])
    }

    func testAtlasPagesStaySingleColumnWhenWidthIsNarrow() {
        let layout = DebugOverlayPanelLayout.atlasGridLayout(
            pageCount: 2,
            width: 320,
            pageLabelHeight: 16,
            pageSpacing: 10,
            minimumPageSide: 180,
            maximumPageSide: 260
        )

        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.height, 562)
        XCTAssertEqual(layout.pageFrames.map(\.pageRect), [
            CGRect(x: 0, y: 16, width: 260, height: 260),
            CGRect(x: 0, y: 302, width: 260, height: 260)
        ])
    }
}
