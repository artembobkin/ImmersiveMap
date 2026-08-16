// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The badge margin: the app-configured distance between the badge and the
/// view edges. The default is 0, so the badge sits tightly in its corner;
/// raising it floats the badge over the map.
final class AttributionBadgeMarginTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let badgeSize = CGSize(width: 120, height: 24)
    private let zeroInsets = PlatformEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    func testTheDefaultMarginIsZero() {
        XCTAssertEqual(ImmersiveMapSettings.AttributionSettings().margin, 0)
        XCTAssertEqual(ImmersiveMapSettings.default.attribution.margin, 0)
    }

    func testZeroMarginPinsTheBadgeIntoTheCorner() {
        let frame = AttributionBadgeLayoutMath.badgeFrame(badgeSize: badgeSize,
                                                          position: .bottomTrailing,
                                                          bounds: bounds,
                                                          safeAreaInsets: zeroInsets,
                                                          margin: 0,
                                                          isRightToLeft: false)

        XCTAssertEqual(frame.maxX, bounds.maxX)
        XCTAssertEqual(frame.maxY, bounds.maxY)
    }

    func testMarginFloatsTheBadgeOffTheEdges() {
        let frame = AttributionBadgeLayoutMath.badgeFrame(badgeSize: badgeSize,
                                                          position: .bottomTrailing,
                                                          bounds: bounds,
                                                          safeAreaInsets: zeroInsets,
                                                          margin: 12,
                                                          isRightToLeft: false)

        XCTAssertEqual(frame.maxX, bounds.maxX - 12)
        XCTAssertEqual(frame.maxY, bounds.maxY - 12)
    }

    func testMarginAppliesAfterTheSafeArea() {
        let insets = PlatformEdgeInsets(top: 20, left: 0, bottom: 34, right: 8)
        let frame = AttributionBadgeLayoutMath.badgeFrame(badgeSize: badgeSize,
                                                          position: .bottomTrailing,
                                                          bounds: bounds,
                                                          safeAreaInsets: insets,
                                                          margin: 10,
                                                          isRightToLeft: false)

        XCTAssertEqual(frame.maxX, bounds.maxX - 8 - 10)
        XCTAssertEqual(frame.maxY, bounds.maxY - 34 - 10)
    }

    func testMarginNarrowsTheAvailableWidth() {
        XCTAssertEqual(AttributionBadgeLayoutMath.availableWidth(bounds: bounds,
                                                                 safeAreaInsets: zeroInsets,
                                                                 margin: 0),
                       bounds.width)
        XCTAssertEqual(AttributionBadgeLayoutMath.availableWidth(bounds: bounds,
                                                                 safeAreaInsets: zeroInsets,
                                                                 margin: 15),
                       bounds.width - 30)
    }

    func testCornersTouchingTheEdgesRenderSquare() {
        // Flush bottom-trailing: only the corner facing the map interior
        // keeps its radius.
        let flush = AttributionBadgeLayoutMath.roundedCorners(
            badgeFrame: CGRect(x: bounds.maxX - 120, y: bounds.maxY - 24, width: 120, height: 24),
            bounds: bounds)
        XCTAssertEqual(flush,
                       AttributionBadgeLayoutMath.RoundedCorners(topLeft: true,
                                                                 topRight: false,
                                                                 bottomLeft: false,
                                                                 bottomRight: false))

        // Flush bottom-center: both top corners face the interior.
        let center = AttributionBadgeLayoutMath.roundedCorners(
            badgeFrame: CGRect(x: 140, y: bounds.maxY - 24, width: 120, height: 24),
            bounds: bounds)
        XCTAssertEqual(center,
                       AttributionBadgeLayoutMath.RoundedCorners(topLeft: true,
                                                                 topRight: true,
                                                                 bottomLeft: false,
                                                                 bottomRight: false))
    }

    func testAFloatingBadgeKeepsAllFourRoundedCorners() {
        // Off every edge, whether by margin or by a safe-area inset: a badge
        // that visibly floats keeps the full pill shape.
        let floating = AttributionBadgeLayoutMath.roundedCorners(
            badgeFrame: CGRect(x: bounds.maxX - 132, y: bounds.maxY - 58, width: 120, height: 24),
            bounds: bounds)
        XCTAssertEqual(floating,
                       AttributionBadgeLayoutMath.RoundedCorners(topLeft: true,
                                                                 topRight: true,
                                                                 bottomLeft: true,
                                                                 bottomRight: true))
    }

    func testMarginBuilderTouchesOnlyTheMargin() {
        let settings = ImmersiveMapSettings.default
            .attributionSettings(margin: 12)

        XCTAssertEqual(settings.attribution.margin, 12)
        XCTAssertEqual(settings.attribution.position,
                       ImmersiveMapSettings.default.attribution.position)
        XCTAssertEqual(settings.attribution.size,
                       ImmersiveMapSettings.default.attribution.size)
    }
}
