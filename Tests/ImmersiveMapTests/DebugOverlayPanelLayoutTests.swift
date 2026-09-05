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

    // MARK: - The tile list's fixed slots

    /// The list reserves the same height whatever it holds, which is what
    /// stops a tile arriving mid-zoom from moving everything under it.
    func testFixedListHeightIsTheSlotLadder() {
        XCTAssertEqual(DebugOverlayPanelLayout.fixedListHeight(slotCount: 12, slotHeight: 28, spacing: 4),
                       12 * 28 + 11 * 4)
        XCTAssertEqual(DebugOverlayPanelLayout.fixedListHeight(slotCount: 1, slotHeight: 28, spacing: 4), 28)
        XCTAssertEqual(DebugOverlayPanelLayout.fixedListHeight(slotCount: 0, slotHeight: 28, spacing: 4), 0)
    }

    func testEqualRowsFillTheirSlotsExactly() {
        let height = DebugOverlayPanelLayout.fixedListHeight(slotCount: 12, slotHeight: 28, spacing: 4)

        let count = DebugOverlayPanelLayout.visibleRowCount(rowHeights: Array(repeating: 28, count: 20),
                                                            spacing: 4,
                                                            availableHeight: height)

        XCTAssertEqual(count, 12, "Twelve slots must hold exactly twelve rows of a slot's height")
    }

    /// Expanding a tile adds shorter child rows, so more of them fit than the
    /// slot count: the reserved height is what is fixed, not the row count.
    func testShorterRowsFitMoreOfThemselves() {
        let height = DebugOverlayPanelLayout.fixedListHeight(slotCount: 12, slotHeight: 28, spacing: 4)

        let count = DebugOverlayPanelLayout.visibleRowCount(rowHeights: Array(repeating: 22, count: 40),
                                                            spacing: 4,
                                                            availableHeight: height)

        XCTAssertGreaterThan(count, 12)
        XCTAssertEqual(CGFloat(count) * 22 + CGFloat(count - 1) * 4 <= height, true,
                       "The rows counted in must actually fit")
        XCTAssertGreaterThan(CGFloat(count + 1) * 22 + CGFloat(count) * 4, height,
                             "And one more must not")
    }

    func testFewerRowsThanSlotsAreAllVisible() {
        let height = DebugOverlayPanelLayout.fixedListHeight(slotCount: 12, slotHeight: 28, spacing: 4)

        let count = DebugOverlayPanelLayout.visibleRowCount(rowHeights: [28, 28, 22],
                                                            spacing: 4,
                                                            availableHeight: height)

        XCTAssertEqual(count, 3)
    }

    func testNoRowFitsInNoSpace() {
        XCTAssertEqual(DebugOverlayPanelLayout.visibleRowCount(rowHeights: [28, 28],
                                                               spacing: 4,
                                                               availableHeight: 0),
                       0)
        XCTAssertEqual(DebugOverlayPanelLayout.visibleRowCount(rowHeights: [],
                                                               spacing: 4,
                                                               availableHeight: 400),
                       0)
    }

    /// The first row pays no spacing, so a list exactly one row tall shows it.
    func testASingleRowNeedsNoSpacing() {
        XCTAssertEqual(DebugOverlayPanelLayout.visibleRowCount(rowHeights: [28, 28],
                                                               spacing: 4,
                                                               availableHeight: 28),
                       1)
        XCTAssertEqual(DebugOverlayPanelLayout.visibleRowCount(rowHeights: [28, 28],
                                                               spacing: 4,
                                                               availableHeight: 31),
                       1,
                       "Three points short of the second row's spacing is still one row")
    }

    func testOverflowTextCountsWhatIsNotShown() {
        XCTAssertEqual(DebugOverlayHUDTextComposer.tilesOverflowText(count: 6), "+6 more")
    }
}
