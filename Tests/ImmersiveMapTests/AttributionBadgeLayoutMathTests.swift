// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Platform-neutral badge geometry: runs under plain `swift test` on any
/// platform, which is the whole point of extracting the math from the two views.
final class AttributionBadgeLayoutMathTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let safeArea = PlatformEdgeInsets(top: 20, left: 10, bottom: 34, right: 5)
    private let badgeSize = CGSize(width: 200, height: 30)

    private var metrics: AttributionBadgeLayoutMath.Metrics {
        AttributionBadgeLayoutMath.metrics(for: .regular)
    }

    /// `.regular` keeps the historical text size and insets, so the
    /// default badge renders as it did.
    func testRegularMetricsMatchLegacyConstants() {
        XCTAssertEqual(metrics.fontSize, 12)
        XCTAssertEqual(metrics.horizontalInset, 10)
        XCTAssertEqual(metrics.verticalInset, 7)
    }

    func testMetricsScaleMonotonically() {
        let small = AttributionBadgeLayoutMath.metrics(for: .small)
        let regular = AttributionBadgeLayoutMath.metrics(for: .regular)
        let large = AttributionBadgeLayoutMath.metrics(for: .large)

        for (smaller, larger) in [(small, regular), (regular, large)] {
            XCTAssertLessThan(smaller.fontSize, larger.fontSize)
            XCTAssertLessThan(smaller.horizontalInset, larger.horizontalInset)
            XCTAssertLessThan(smaller.verticalInset, larger.verticalInset)
        }
    }

    // A non-zero margin, so the frame math is exercised with all three
    // offsets (safe area, margin, badge size) in play; the zero default is
    // covered by `AttributionBadgeMarginTests`.
    private func frame(_ position: ImmersiveMapSettings.AttributionSettings.Position,
                       isRightToLeft: Bool = false) -> CGRect {
        AttributionBadgeLayoutMath.badgeFrame(badgeSize: badgeSize,
                                              position: position,
                                              bounds: bounds,
                                              safeAreaInsets: safeArea,
                                              margin: 12,
                                              isRightToLeft: isRightToLeft)
    }

    func testBadgeFrameForEveryPosition() {
        // contentRect: x 22...783, y 32...554 (safe area + margin 12).
        XCTAssertEqual(frame(.bottomTrailing),
                       CGRect(x: 783 - 200, y: 554 - 30, width: 200, height: 30))
        XCTAssertEqual(frame(.bottomLeading),
                       CGRect(x: 22, y: 554 - 30, width: 200, height: 30))
        XCTAssertEqual(frame(.topTrailing),
                       CGRect(x: 783 - 200, y: 32, width: 200, height: 30))
        XCTAssertEqual(frame(.topLeading),
                       CGRect(x: 22, y: 32, width: 200, height: 30))
        XCTAssertEqual(frame(.bottomCenter),
                       CGRect(x: (22.0 + 783.0) / 2 - 100, y: 554 - 30, width: 200, height: 30))
        XCTAssertEqual(frame(.topCenter),
                       CGRect(x: (22.0 + 783.0) / 2 - 100, y: 32, width: 200, height: 30))
    }

    /// RTL mirrors leading/trailing but never the centers.
    func testRightToLeftFlipsLeadingAndTrailingOnly() {
        XCTAssertEqual(frame(.bottomTrailing, isRightToLeft: true).minX,
                       frame(.bottomLeading).minX)
        XCTAssertEqual(frame(.topLeading, isRightToLeft: true).minX,
                       frame(.topTrailing).minX)
        XCTAssertEqual(frame(.bottomCenter, isRightToLeft: true),
                       frame(.bottomCenter))
        XCTAssertEqual(frame(.topCenter, isRightToLeft: true),
                       frame(.topCenter))
    }

    func testAvailableWidthSubtractsSafeAreaAndMargins() {
        let width = AttributionBadgeLayoutMath.availableWidth(bounds: bounds,
                                                              safeAreaInsets: safeArea,
                                                              margin: 12)

        XCTAssertEqual(width, 800 - 10 - 5 - 12 * 2)
    }

    /// The badge is the line and its insets.
    func testBadgeSizeIsTheLineAndItsInsets() {
        let size = AttributionBadgeLayoutMath.badgeSize(textSize: CGSize(width: 120, height: 15),
                                                        metrics: metrics,
                                                        boundingWidth: 400)

        XCTAssertEqual(size.height, ceil(15 + metrics.verticalInset * 2))
        XCTAssertEqual(size.width, ceil(120 + metrics.horizontalInset * 2))
    }

    /// A line longer than the width it is given fills that width, and the
    /// label cuts it: the line may run along the whole edge of the map and
    /// no further.
    func testBadgeSizeClampsToTheBoundingWidth() {
        let size = AttributionBadgeLayoutMath.badgeSize(textSize: CGSize(width: 1000, height: 15),
                                                        metrics: metrics,
                                                        boundingWidth: 400)

        XCTAssertEqual(size.width, 400)
    }

    /// The line sits inside the insets.
    func testLabelFrameIsTheBadgeLessItsInsets() {
        let badgeBounds = CGRect(x: 0, y: 0, width: 150, height: 40)

        let frame = AttributionBadgeLayoutMath.labelFrame(badgeBounds: badgeBounds, metrics: metrics)

        XCTAssertEqual(frame.minX, metrics.horizontalInset)
        XCTAssertEqual(frame.minY, metrics.verticalInset)
        XCTAssertEqual(frame.width, 150 - metrics.horizontalInset * 2)
        XCTAssertEqual(frame.height, 40 - metrics.verticalInset * 2)
    }
}
