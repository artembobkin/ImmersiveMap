// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest

final class DebugOverlayZoomBadgeTests: XCTestCase {
    /// The camera's zoom over the planning zoom, to two places.
    func testTheBadgeReadsBothZooms() {
        XCTAssertEqual(DebugOverlayZoomBadge.lines(zoom: 12.604, planningZoom: 11.5), ["z 12.60", "plan 11.50"])
    }

    /// In the top trailing corner, under the safe area, the margin off both
    /// edges, and in the leading corner for a right-to-left layout.
    func testTheBadgeSitsInTheTopTrailingCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 120, height: 60)
        XCTAssertEqual(DebugOverlayZoomBadge.frame(size: size, bounds: bounds, topInset: 20, isRightToLeft: false),
                       CGRect(x: 800 - 16 - 120, y: 36, width: 120, height: 60))
        XCTAssertEqual(DebugOverlayZoomBadge.frame(size: size, bounds: bounds, topInset: 0, isRightToLeft: true).minX, 16)
    }

    /// Shown with the panel by default, and an omitted value leaves it as
    /// configured.
    func testTheDebugPanelModifierSetsTheBadge() {
        XCTAssertTrue(ImmersiveMapSettings.default.debugPanel().debug.showsZoomBadge)
        let off = ImmersiveMapSettings.default.debugPanel(zoomBadge: false)
        XCTAssertFalse(off.debug.showsZoomBadge)
        XCTAssertFalse(off.debugPanel().debug.showsZoomBadge, "An omitted badge is left as configured")
    }
}
