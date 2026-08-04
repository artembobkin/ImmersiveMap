// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import SwiftUI
import XCTest

/// Placement math in the bottom-up pixel space shared by the marker
/// projection and CoreGraphics. `UnitPoint.y` is measured from the view's top.
final class VideoExportMarkerCompositorMathTests: XCTestCase {
    private let sizePx = CGSize(width: 80, height: 40)
    private let point = SIMD2<Float>(100, 200)

    func testCenterAnchorCentersTheImageOnThePoint() {
        let rect = VideoExportMarkerCompositorMath.rectPx(anchorPointPx: point,
                                                          sizePx: sizePx,
                                                          anchor: .center)
        XCTAssertEqual(rect, CGRect(x: 60, y: 180, width: 80, height: 40))
    }

    func testBottomAnchorPutsTheImageAboveThePoint() {
        // .bottom: the bottom edge of the marker touches the point, the image
        // extends upward: in y-up space the rect starts at the point.
        let rect = VideoExportMarkerCompositorMath.rectPx(anchorPointPx: point,
                                                          sizePx: sizePx,
                                                          anchor: .bottom)
        XCTAssertEqual(rect, CGRect(x: 60, y: 200, width: 80, height: 40))
    }

    func testTopLeadingAnchorPutsTheImageBelowAndRightOfThePoint() {
        let rect = VideoExportMarkerCompositorMath.rectPx(anchorPointPx: point,
                                                          sizePx: sizePx,
                                                          anchor: .topLeading)
        XCTAssertEqual(rect, CGRect(x: 100, y: 160, width: 80, height: 40))
    }
}
