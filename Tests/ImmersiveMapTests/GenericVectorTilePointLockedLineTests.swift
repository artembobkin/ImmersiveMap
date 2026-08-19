// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Pins the public `.pointLockedLine` style case to the point-locked line
/// principle (`FeatureStyle.pointLockedLine`): a custom style opting in must
/// get all five decisions, and a style that does not opt in must get none.
final class GenericVectorTilePointLockedLineTests: XCTestCase {
    private func makeStyle(_ vectorStyle: any ImmersiveMapVectorTileStyle) -> GenericVectorTileStyle {
        GenericVectorTileStyle(providerID: "custom",
                               style: vectorStyle,
                               settings: ImmersiveMapSettings.default.style)
    }

    private func featureStyle(of vectorStyle: any ImmersiveMapVectorTileStyle,
                              layer: String = "boundary") -> FeatureStyle {
        makeStyle(vectorStyle).makeStyle(data: DetFeatureStyleData(layerName: layer,
                                                                   properties: [:],
                                                                   tile: Tile(x: 1, y: 2, z: 6)))
    }

    func testPointLockedLineCarriesTheWholePrinciple() {
        let color = SIMD4<Float>(0.4, 0.3, 0.5, 0.9)
        let style = featureStyle(of: FixedStyle(style: .pointLockedLine(color: color,
                                                                        widthPoints: 1.3,
                                                                        dashLengthPoints: 6,
                                                                        dashGapPoints: 3)))

        XCTAssertEqual(style.color, color)
        XCTAssertEqual(style.lineWidthPoints, 1.3, "The width is point-locked")
        XCTAssertEqual(style.lowZoomFadeMask, 1.0, "Opaque from the first visible frame: the overview band")
        XCTAssertFalse(style.parseGeometryStyleData.lineCapRound, "Butt ends")
        XCTAssertFalse(style.parseGeometryStyleData.lineJoinRound, "Plain joins")
        XCTAssertEqual(style.dashLengthPoints, 6, "Dashes are stated in points")
        XCTAssertEqual(style.dashGapPoints, 3)
        XCTAssertFalse(style.parseGeometryStyleData.usesDashPattern,
                       "Point dashes are shader-cut; the tessellation stays a continuous ribbon")
        XCTAssertEqual(style.parseGeometryStyleData.lineWidth,
                       Double(Float(1.3)) * FeatureStyle.pointLockedRibbonUnitsPerPoint,
                       accuracy: 0.001,
                       "The ribbon must host the point width")
        XCTAssertTrue(style.suppressPolygonFill,
                      "Areal geometry under a line mode draws outlines only")
    }

    func testPlainLineOptsIntoNoneOfIt() {
        let style = featureStyle(of: FixedStyle(style: .line(color: SIMD4<Float>(1, 1, 1, 1), width: 2)))

        XCTAssertEqual(style.lineWidthPoints, 0)
        XCTAssertEqual(style.parseGeometryStyleData.lineWidth, 2, "A plain line width lives in tile units")
        XCTAssertFalse(style.suppressPolygonFill)
    }

    func testStyleKeySeparatesTheModeAndItsValues() {
        let color = SIMD4<Float>(0.4, 0.3, 0.5, 0.9)
        func key(_ style: ImmersiveMapFeatureStyle) -> UInt8 {
            featureStyle(of: FixedStyle(style: style)).key
        }

        // The mode itself, the width, and the dash pattern all separate the
        // prepared-tile style identity; a repeated description does not.
        let base = key(.pointLockedLine(color: color, widthPoints: 1.3))
        XCTAssertEqual(base, key(.pointLockedLine(color: color, widthPoints: 1.3)))
        XCTAssertNotEqual(base, key(.line(color: color, width: 1.3)))
        XCTAssertNotEqual(base, key(.pointLockedLine(color: color, widthPoints: 2.0)))
        XCTAssertNotEqual(base, key(.pointLockedLine(color: color, widthPoints: 1.3,
                                                     dashLengthPoints: 6, dashGapPoints: 3)))
    }
}

// @unchecked: the payloads are all value types; the enum just does not
// declare Sendable today.
private struct FixedStyle: ImmersiveMapVectorTileStyle, @unchecked Sendable {
    let style: ImmersiveMapFeatureStyle
    var cacheFingerprint: UInt32 { 1 }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        style
    }
}
