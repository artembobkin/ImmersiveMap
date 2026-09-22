// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The `FeatureStyle` factories are the drawing modes a custom style states
/// with one call; each must set every knob the mode consists of.
final class FeatureStyleFactoryTests: XCTestCase {
    private let textStyle = LabelTextStyle(fillColor: SIMD3<Float>(0.2, 0.2, 0.18),
                                           strokeColor: SIMD3<Float>(1.0, 0.98, 0.92),
                                           haloEm: 0.15,
                                           sizePoints: 14,
                                           weight: .bold)

    func testPointLabelKeysTheTextStyleAndDrawsNoGeometry() {
        let style = FeatureStyle.pointLabel(key: 70, textStyle, minCameraZoom: 9)

        XCTAssertEqual(style.key, 70)
        XCTAssertNil(style.primaryPass, "A label draws no geometry of its own")
        XCTAssertEqual(style.labelTextStyle?.key, 70, "The text style carries the feature style's key")
        XCTAssertEqual(style.labelTextStyle?.fillColor, SIMD3<Float>(0.2, 0.2, 0.18))
        XCTAssertEqual(style.labelTextStyle?.sizePoints, 14)
        XCTAssertEqual(style.labelTextStyle?.weight, .bold)
        XCTAssertEqual(style.labelMinCameraZoom, 9)
        XCTAssertNil(style.roadLabelTextStyle)
    }

    func testLabelSizesBelowTheReadableFloorAreRaisedToIt() {
        var small = textStyle
        small.sizePoints = 6
        XCTAssertEqual(FeatureStyle.pointLabel(key: 1, small).labelTextStyle?.sizePoints,
                       LabelTypeScale.minimumSizePoints)
    }

    func testRoadLabelIsALineWithTheNameAlongIt() {
        let style = FeatureStyle.roadLabel(key: 40,
                                           color: SIMD4<Float>(0.96, 0.94, 0.90, 1.0),
                                           width: 1.6,
                                           textStyle: textStyle)

        XCTAssertEqual(style.color, SIMD4<Float>(0.96, 0.94, 0.90, 1.0))
        XCTAssertEqual(style.lineGeometry.lineWidth, 1.6, accuracy: 0.0001)
        XCTAssertTrue(style.includeRoadLabelPath)
        XCTAssertNil(style.labelTextStyle)
        XCTAssertEqual(style.roadLabelTextStyle?.key, 40)
        XCTAssertEqual(style.roadLabelTextStyle?.weight, .bold)
    }

    func testPointLockedLineCarriesTheWholePrinciple() {
        let color = SIMD4<Float>(0.4, 0.3, 0.5, 0.9)
        let style = FeatureStyle.pointLockedLine(key: 100,
                                                 color: color,
                                                 widthPoints: 1.3,
                                                 dashLengthPoints: 6,
                                                 dashGapPoints: 3)

        XCTAssertEqual(style.color, color)
        XCTAssertEqual(style.lineWidthPoints, 1.3, "The width is point-locked")
        XCTAssertEqual(style.lowZoomFadeMask, 1.0, "Opaque from the first visible frame: the overview band")
        XCTAssertFalse(style.lineGeometry.lineCapRound, "Butt ends")
        XCTAssertFalse(style.lineGeometry.lineJoinRound, "Plain joins")
        XCTAssertEqual(style.dashLengthPoints, 6, "Dashes are stated in points")
        XCTAssertEqual(style.dashGapPoints, 3)
        XCTAssertFalse(style.lineGeometry.usesDashPattern,
                       "Point dashes are shader-cut; the tessellation stays a continuous ribbon")
        XCTAssertEqual(style.lineGeometry.lineWidth,
                       Double(Float(1.3)) * FeatureStyle.pointLockedRibbonUnitsPerPoint,
                       accuracy: 0.001,
                       "The ribbon must host the point width")
        XCTAssertTrue(style.suppressPolygonFill,
                      "Areal geometry under a line mode draws outlines only")
    }

    func testPlainLineOptsIntoNoneOfIt() {
        let style = FeatureStyle.line(key: 44, color: SIMD4<Float>(1, 1, 1, 1), width: 2)

        XCTAssertEqual(style.lineWidthPoints, 0)
        XCTAssertEqual(style.lineGeometry.lineWidth, 2, "A plain line width lives in tile units")
        XCTAssertFalse(style.suppressPolygonFill)
        XCTAssertFalse(style.isExtruded)
    }

    func testExtrudedPolygonRisesAndAPolygonDoesNot() {
        XCTAssertTrue(FeatureStyle.extrudedPolygon(key: 30, color: SIMD4<Float>(1, 1, 1, 1), fallbackHeight: 8).isExtruded)
        XCTAssertEqual(FeatureStyle.extrudedPolygon(key: 30, color: SIMD4<Float>(1, 1, 1, 1), fallbackHeight: 8).extrusionFallbackHeight, 8)
        XCTAssertFalse(FeatureStyle.polygon(key: 30, color: SIMD4<Float>(1, 1, 1, 1)).isExtruded)
    }

    func testHiddenIsKeyZero() {
        XCTAssertEqual(FeatureStyle.hidden.key, 0, "Key 0 is what the parser skips")
    }
}
