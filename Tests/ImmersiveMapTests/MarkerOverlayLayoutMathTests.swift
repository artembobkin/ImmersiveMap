// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import SwiftUI
import XCTest

/// Конверсия drawable-пикселей проекции (origin снизу слева, y вверх) в
/// поинты view (origin сверху слева) и позиционирование по якорю UnitPoint.
final class MarkerOverlayLayoutMathTests: XCTestCase {
    private let drawSize = CGSize(width: 800, height: 600)

    func testPointFromPixelFlipsYAndDividesByScale() {
        let point = MarkerOverlayLayoutMath.pointFromPixel(SIMD2<Float>(400, 150),
                                                           drawSize: drawSize,
                                                           contentsScale: 2)

        XCTAssertEqual(point.x, 200)
        XCTAssertEqual(point.y, 225)
    }

    func testPointFromPixelScaleOneKeepsPixels() {
        let point = MarkerOverlayLayoutMath.pointFromPixel(SIMD2<Float>(400, 150),
                                                           drawSize: drawSize,
                                                           contentsScale: 1)

        XCTAssertEqual(point.x, 400)
        XCTAssertEqual(point.y, 450)
    }

    func testPointFromPixelScaleThree() {
        let point = MarkerOverlayLayoutMath.pointFromPixel(SIMD2<Float>(300, 0),
                                                           drawSize: drawSize,
                                                           contentsScale: 3)

        XCTAssertEqual(point.x, 100)
        XCTAssertEqual(point.y, 200)
    }

    func testPointFromPixelZeroScaleReturnsZero() {
        let point = MarkerOverlayLayoutMath.pointFromPixel(SIMD2<Float>(400, 150),
                                                           drawSize: drawSize,
                                                           contentsScale: 0)

        XCTAssertEqual(point, .zero)
    }

    func testFrameCenterAnchorCentersViewOnPoint() {
        let frame = MarkerOverlayLayoutMath.frame(anchorPoint: CGPoint(x: 100, y: 100),
                                                  size: CGSize(width: 40, height: 20),
                                                  anchor: .center)

        XCTAssertEqual(frame, CGRect(x: 80, y: 90, width: 40, height: 20))
    }

    func testFrameBottomAnchorPutsBottomCenterOnPoint() {
        let frame = MarkerOverlayLayoutMath.frame(anchorPoint: CGPoint(x: 100, y: 100),
                                                  size: CGSize(width: 40, height: 20),
                                                  anchor: .bottom)

        XCTAssertEqual(frame, CGRect(x: 80, y: 80, width: 40, height: 20))
    }

    func testFrameTopLeadingAnchorPutsOriginOnPoint() {
        let frame = MarkerOverlayLayoutMath.frame(anchorPoint: CGPoint(x: 100, y: 100),
                                                  size: CGSize(width: 40, height: 20),
                                                  anchor: .topLeading)

        XCTAssertEqual(frame, CGRect(x: 100, y: 100, width: 40, height: 20))
    }
}
