// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class MapboxDefaultMapStyleLabelStrokeTests: XCTestCase {
    func testBaseLabelsUseWiderWhiteStroke() {
        XCTAssertEqual(baseLabelStroke(layerName: "place_label",
                                       properties: ["type": stringValue("city")]),
                       5.4,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "place_label",
                                       properties: ["capital": intValue(2)]),
                       7.8,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "poi_label",
                                       properties: ["type": stringValue("restaurant")]),
                       7.2,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "airport_label"),
                       7.8,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "housenum_label"),
                       8.1,
                       accuracy: 0.0001)
    }

    func testHouseNumberLabelsUseReducedFontSize() {
        XCTAssertEqual(baseLabelSize(layerName: "housenum_label", zoom: 16),
                       24.0,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelSize(layerName: "housenum_label", zoom: 17),
                       26.0,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelSize(layerName: "housenum_label", zoom: 18),
                       28.0,
                       accuracy: 0.0001)
    }

    func testDistrictLabelsUseSubtleWhiteStroke() {
        XCTAssertEqual(baseLabelStroke(layerName: "place_label",
                                       properties: ["class": stringValue("settlement_subdivision")]),
                       2.7,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "place_label",
                                       properties: ["type": stringValue("quarter")]),
                       2.7,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "place_label",
                                       properties: ["type": stringValue("neighbourhood")]),
                       2.7,
                       accuracy: 0.0001)
    }

    func testWaterLabelsScaleStrokeDownForSmallText() {
        XCTAssertEqual(baseLabelStroke(layerName: "natural_label",
                                       properties: ["class": stringValue("ocean")],
                                       zoom: 10),
                       2.52,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "natural_label",
                                       properties: ["class": stringValue("ocean")],
                                       zoom: 1),
                       3.78,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "natural_label",
                                       properties: ["class": stringValue("sea")],
                                       zoom: 2),
                       4.76,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelStroke(layerName: "natural_label",
                                       properties: ["class": stringValue("sea")],
                                       zoom: 1),
                       5.4,
                       accuracy: 0.0001)
    }

    func testRoadLabelsKeepExistingStrokeWidth() {
        let style = makeStyle(layerName: "road",
                              properties: ["class": stringValue("primary")],
                              zoom: 14)
        guard let roadLabelTextStyle = style.roadLabelTextStyle else {
            XCTFail("Expected road label style")
            return
        }

        XCTAssertEqual(roadLabelTextStyle.strokeWidthPx, 2.6, accuracy: 0.0001)
    }

    func testCustomMapStyleControlsDistrictLabelStroke() {
        let mapStyle = MapboxDefaultMapStyleConfiguration.mapboxDefault.labels { labels in
            labels.district.strokeWidthPx = 1.4
            labels.district.fillColor = SIMD3<Float>(0.2, 0.3, 0.4)
        }

        let style = makeStyle(layerName: "place_label",
                              properties: ["type": stringValue("quarter")],
                              zoom: 10,
                              configuration: mapStyle)

        XCTAssertEqual(style.labelTextStyle?.strokeWidthPx ?? -1, 1.4, accuracy: 0.0001)
        XCTAssertEqual(style.labelTextStyle?.fillColor, SIMD3<Float>(0.2, 0.3, 0.4))
    }

    private func baseLabelStroke(layerName: String,
                                 properties: [String: VectorTile_Tile.Value] = [:],
                                 zoom: Int = 10) -> Float {
        let style = makeStyle(layerName: layerName, properties: properties, zoom: zoom)
        guard let labelTextStyle = style.labelTextStyle else {
            XCTFail("Expected base label style for \(layerName)")
            return -1
        }
        return labelTextStyle.strokeWidthPx
    }

    private func baseLabelSize(layerName: String,
                               properties: [String: VectorTile_Tile.Value] = [:],
                               zoom: Int = 10) -> Float {
        let style = makeStyle(layerName: layerName, properties: properties, zoom: zoom)
        guard let labelTextStyle = style.labelTextStyle else {
            XCTFail("Expected base label style for \(layerName)")
            return -1
        }
        return labelTextStyle.sizePx
    }

    private func makeStyle(layerName: String,
                           properties: [String: VectorTile_Tile.Value],
                           zoom: Int,
                           configuration: MapboxDefaultMapStyleConfiguration = .mapboxDefault,
                           styleSettings: ImmersiveMapSettings.StyleSettings = ImmersiveMapSettings.default.style) -> FeatureStyle {
        MapboxDefaultMapStyle(configuration: configuration,
                              settings: styleSettings).makeStyle(
            data: DetFeatureStyleData(layerName: layerName,
                                      properties: properties,
                                      tile: Tile(x: 0, y: 0, z: zoom))
        )
    }

    private func stringValue(_ value: String) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.stringValue = value
        return tileValue
    }

    private func intValue(_ value: Int64) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.intValue = value
        return tileValue
    }
}
