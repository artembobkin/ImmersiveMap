// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Platform-neutral badge geometry: runs under plain `swift test` on any
/// platform — the whole point of extracting the math from the two views.
final class AttributionBadgeLayoutMathTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let safeArea = PlatformEdgeInsets(top: 20, left: 10, bottom: 34, right: 5)
    private let badgeSize = CGSize(width: 200, height: 30)

    private var metrics: AttributionBadgeLayoutMath.Metrics {
        AttributionBadgeLayoutMath.metrics(for: .regular)
    }

    /// `.regular` must equal the historical constants exactly: the default
    /// badge renders pixel-identical to the pre-customization one.
    func testRegularMetricsMatchLegacyConstants() {
        XCTAssertEqual(metrics.titleFontSize, 12)
        XCTAssertEqual(metrics.copyrightFontSize, 10)
        XCTAssertEqual(metrics.horizontalInset, 10)
        XCTAssertEqual(metrics.verticalInset, 7)
        XCTAssertEqual(metrics.interLabelSpacing, 2)
        XCTAssertEqual(metrics.cornerRadius, 8)
        XCTAssertEqual(metrics.containerInset, 12)
        XCTAssertEqual(metrics.maximumWidth, 240)
    }

    func testMetricsScaleMonotonically() {
        let small = AttributionBadgeLayoutMath.metrics(for: .small)
        let regular = AttributionBadgeLayoutMath.metrics(for: .regular)
        let large = AttributionBadgeLayoutMath.metrics(for: .large)

        for (smaller, larger) in [(small, regular), (regular, large)] {
            XCTAssertLessThan(smaller.titleFontSize, larger.titleFontSize)
            XCTAssertLessThan(smaller.copyrightFontSize, larger.copyrightFontSize)
            XCTAssertLessThan(smaller.horizontalInset, larger.horizontalInset)
            XCTAssertLessThan(smaller.verticalInset, larger.verticalInset)
            XCTAssertLessThan(smaller.cornerRadius, larger.cornerRadius)
            XCTAssertLessThan(smaller.containerInset, larger.containerInset)
            XCTAssertLessThan(smaller.maximumWidth, larger.maximumWidth)
        }
    }

    private func frame(_ position: ImmersiveMapSettings.AttributionSettings.Position,
                       isRightToLeft: Bool = false) -> CGRect {
        AttributionBadgeLayoutMath.badgeFrame(badgeSize: badgeSize,
                                              position: position,
                                              bounds: bounds,
                                              safeAreaInsets: safeArea,
                                              metrics: metrics,
                                              isRightToLeft: isRightToLeft)
    }

    func testBadgeFrameForEveryPosition() {
        // contentRect: x 22...783, y 32...554 (safe area + containerInset 12).
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

    func testAvailableWidthSubtractsSafeAreaAndContainerInsets() {
        let width = AttributionBadgeLayoutMath.availableWidth(bounds: bounds,
                                                              safeAreaInsets: safeArea,
                                                              metrics: metrics)

        XCTAssertEqual(width, 800 - 10 - 5 - 12 * 2)
    }

    /// A zero copyright size adds neither the second row nor the spacing.
    func testBadgeSizeCollapsesEmptyCopyright() {
        let titleSize = CGSize(width: 120, height: 15)
        let copyrightSize = CGSize(width: 100, height: 12)

        let twoLine = AttributionBadgeLayoutMath.badgeSize(titleSize: titleSize,
                                                           copyrightSize: copyrightSize,
                                                           metrics: metrics,
                                                           boundingWidth: 400)
        let oneLine = AttributionBadgeLayoutMath.badgeSize(titleSize: titleSize,
                                                           copyrightSize: .zero,
                                                           metrics: metrics,
                                                           boundingWidth: 400)

        XCTAssertEqual(oneLine.height, ceil(15 + metrics.verticalInset * 2))
        XCTAssertEqual(twoLine.height, ceil(15 + 12 + metrics.interLabelSpacing + metrics.verticalInset * 2))
        XCTAssertEqual(oneLine.width, ceil(120 + metrics.horizontalInset * 2))
    }

    func testBadgeSizeClampsToMaximumWidth() {
        let size = AttributionBadgeLayoutMath.badgeSize(titleSize: CGSize(width: 1000, height: 15),
                                                        copyrightSize: .zero,
                                                        metrics: metrics,
                                                        boundingWidth: 400)

        XCTAssertEqual(size.width, metrics.maximumWidth)
    }

    /// Label stacking mirrors the plate math: spacing exists only when the
    /// copyright line does.
    func testLabelFramesStackWithSpacingOnlyWhenCopyrightPresent() {
        let badgeBounds = CGRect(x: 0, y: 0, width: 150, height: 40)

        let twoLine = AttributionBadgeLayoutMath.labelFrames(badgeBounds: badgeBounds,
                                                             titleHeight: 15,
                                                             copyrightHeight: 12,
                                                             metrics: metrics)
        XCTAssertEqual(twoLine.title.minY, metrics.verticalInset)
        XCTAssertEqual(twoLine.copyright.minY, metrics.verticalInset + 15 + metrics.interLabelSpacing)
        XCTAssertEqual(twoLine.copyright.height, 12)

        let oneLine = AttributionBadgeLayoutMath.labelFrames(badgeBounds: badgeBounds,
                                                             titleHeight: 15,
                                                             copyrightHeight: 0,
                                                             metrics: metrics)
        XCTAssertEqual(oneLine.copyright.height, 0)
        XCTAssertEqual(oneLine.copyright.minY, oneLine.title.maxY)
    }
}
