// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class GenericVectorTileStyleLabelTests: XCTestCase {
    func testPointLabelStyleMapsToInternalLabelTextStyle() {
        let style = GenericVectorTileStyle(
            providerID: "custom",
            style: CustomLabelVectorTileStyle(),
            settings: ImmersiveMapSettings.default.style
        )

        let featureStyle = style.makeStyle(data: DetFeatureStyleData(
            layerName: "place_labels",
            properties: [:],
            tile: Tile(x: 1, y: 2, z: 10)
        ))

        XCTAssertEqual(featureStyle.color, SIMD4<Float>(0, 0, 0, 0))
        XCTAssertEqual(featureStyle.parseGeometryStyleData.lineWidth, 0)
        XCTAssertEqual(featureStyle.labelTextStyle?.fillColor, SIMD3<Float>(0.2, 0.2, 0.18))
        XCTAssertEqual(featureStyle.labelTextStyle?.strokeColor, SIMD3<Float>(1.0, 0.98, 0.92))
        XCTAssertEqual(featureStyle.labelTextStyle?.strokeWidthPx, 2)
        XCTAssertEqual(featureStyle.labelTextStyle?.sizePx, 14)
        XCTAssertEqual(featureStyle.labelTextStyle?.weight, .bold)
        XCTAssertNil(featureStyle.roadLabelTextStyle)
    }

    func testRoadLabelStyleMapsToLineAndInternalRoadLabelTextStyle() {
        let style = GenericVectorTileStyle(
            providerID: "custom",
            style: CustomLabelVectorTileStyle(),
            settings: ImmersiveMapSettings.default.style
        )

        let featureStyle = style.makeStyle(data: DetFeatureStyleData(
            layerName: "transportation_name",
            properties: [:],
            tile: Tile(x: 1, y: 2, z: 10)
        ))

        XCTAssertEqual(featureStyle.color, SIMD4<Float>(0.96, 0.94, 0.90, 1.0))
        XCTAssertEqual(featureStyle.parseGeometryStyleData.lineWidth, 1.6, accuracy: 0.0001)
        XCTAssertTrue(featureStyle.includeRoadLabelPath)
        XCTAssertNil(featureStyle.labelTextStyle)
        XCTAssertEqual(featureStyle.roadLabelTextStyle?.fillColor, SIMD3<Float>(0.42, 0.41, 0.39))
        XCTAssertEqual(featureStyle.roadLabelTextStyle?.strokeColor, SIMD3<Float>(1.0, 0.98, 0.92))
        XCTAssertEqual(featureStyle.roadLabelTextStyle?.strokeWidthPx, 2)
        XCTAssertEqual(featureStyle.roadLabelTextStyle?.sizePx, 11)
        XCTAssertEqual(featureStyle.roadLabelTextStyle?.weight, .thin)
    }
}

private struct CustomLabelVectorTileStyle: ImmersiveMapVectorTileStyle {
    var cacheFingerprint: UInt32 {
        1
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        switch feature.layerName {
        case "place_labels":
            return .pointLabel(
                ImmersiveMapLabelTextStyle(
                    fillColor: SIMD3<Float>(0.2, 0.2, 0.18),
                    strokeColor: SIMD3<Float>(1.0, 0.98, 0.92),
                    strokeWidthPx: 2,
                    sizePx: 14,
                    weight: .bold
                )
            )
        case "transportation_name":
            return .roadLabel(
                color: SIMD4<Float>(0.96, 0.94, 0.90, 1.0),
                width: 1.6,
                textStyle: ImmersiveMapLabelTextStyle(
                    fillColor: SIMD3<Float>(0.42, 0.41, 0.39),
                    strokeColor: SIMD3<Float>(1.0, 0.98, 0.92),
                    strokeWidthPx: 2,
                    sizePx: 11,
                    weight: .thin
                )
            )
        default:
            return .hidden
        }
    }
}
