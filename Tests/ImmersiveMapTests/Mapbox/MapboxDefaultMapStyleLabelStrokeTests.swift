// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class MapboxDefaultMapStyleLabelStrokeTests: XCTestCase {
    func testBaseLabelsUseWiderWhiteHalo() {
        XCTAssertEqual(baseLabelHaloEm(layerName: "place_label",
                                       properties: ["type": stringValue("city")]),
                       0.159,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelHaloEm(layerName: "place_label",
                                       properties: ["capital": intValue(2)]),
                       0.159,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelHaloEm(layerName: "poi_label",
                                       properties: ["type": stringValue("restaurant")]),
                       0.300,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelHaloEm(layerName: "airport_label"),
                       0.325,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelHaloEm(layerName: "housenum_label"),
                       0.312,
                       accuracy: 0.0001)
    }

    func testHouseNumberLabelsUseReducedFontSize() {
        XCTAssertEqual(baseLabelSizePoints(layerName: "housenum_label", zoom: 16),
                       12.0,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelSizePoints(layerName: "housenum_label", zoom: 17),
                       13.0,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelSizePoints(layerName: "housenum_label", zoom: 18),
                       14.0,
                       accuracy: 0.0001)
    }

    func testDistrictLabelsUseSubtleWhiteHalo() {
        XCTAssertEqual(baseLabelHaloEm(layerName: "place_label",
                                       properties: ["class": stringValue("settlement_subdivision")]),
                       0.113,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelHaloEm(layerName: "place_label",
                                       properties: ["type": stringValue("quarter")]),
                       0.113,
                       accuracy: 0.0001)
        XCTAssertEqual(baseLabelHaloEm(layerName: "place_label",
                                       properties: ["type": stringValue("neighbourhood")]),
                       0.113,
                       accuracy: 0.0001)
    }

    /// The halo used to be an absolute width that a helper scaled down for small
    /// water labels. As an em ratio it tracks the size on its own, which is the
    /// property worth pinning: the drawn width has to fall with the text.
    func testWaterLabelHaloTracksTheTextSize() {
        let smallOcean = makeWaterLabelStyle(class: "ocean", zoom: 10)
        let largeSea = makeWaterLabelStyle(class: "sea", zoom: 1)

        XCTAssertEqual(smallOcean.haloEm, 0.140, accuracy: 0.0001)
        XCTAssertEqual(largeSea.haloEm, 0.140, accuracy: 0.0001)
        XCTAssertLessThan(smallOcean.sizePoints, largeSea.sizePoints)

        let scale = ScreenScale.reference
        XCTAssertLessThan(smallOcean.haloWidthPixels(screenScale: scale),
                          largeSea.haloWidthPixels(screenScale: scale))
    }

    func testSizesUnderTheReadableFloorAreRaisedToIt() {
        // The ocean curve asks for 9 points at zoom 10, which is under the floor.
        XCTAssertEqual(baseLabelSizePoints(layerName: "natural_label",
                                           properties: ["class": stringValue("ocean")],
                                           zoom: 10),
                       LabelTypeScale.minimumSizePoints,
                       accuracy: 0.0001)
        // At zoom 1 it asks for 13.5, which is above the floor and stays.
        XCTAssertEqual(baseLabelSizePoints(layerName: "natural_label",
                                           properties: ["class": stringValue("ocean")],
                                           zoom: 1),
                       13.5,
                       accuracy: 0.0001)
    }

    func testRoadLabelsKeepExistingHaloRatio() {
        let style = makeStyle(layerName: "road",
                              properties: ["class": stringValue("primary")],
                              zoom: 14)
        guard let roadLabelTextStyle = style.roadLabelTextStyle else {
            XCTFail("Expected road label style")
            return
        }

        XCTAssertEqual(roadLabelTextStyle.haloEm, 0.072, accuracy: 0.0001)
        XCTAssertEqual(roadLabelTextStyle.sizePoints, 18.0, accuracy: 0.0001)
    }

    func testCustomMapStyleControlsDistrictLabelHalo() {
        let mapStyle = MapboxDefaultMapStyleConfiguration.mapboxDefault.labels { labels in
            labels.district.haloEm = 0.14
            labels.district.fillColor = SIMD3<Float>(0.2, 0.3, 0.4)
        }

        let style = makeStyle(layerName: "place_label",
                              properties: ["type": stringValue("quarter")],
                              zoom: 10,
                              configuration: mapStyle)

        XCTAssertEqual(style.labelTextStyle?.haloEm ?? -1, 0.14, accuracy: 0.0001)
        XCTAssertEqual(style.labelTextStyle?.fillColor, SIMD3<Float>(0.2, 0.3, 0.4))
    }

    private func makeWaterLabelStyle(class classValue: String, zoom: Int) -> LabelTextStyle {
        let style = makeStyle(layerName: "natural_label",
                              properties: ["class": stringValue(classValue)],
                              zoom: zoom)
        guard let labelTextStyle = style.labelTextStyle else {
            XCTFail("Expected a water label style")
            return RoadLabelCache.fallbackStyle
        }
        return labelTextStyle
    }

    private func baseLabelHaloEm(layerName: String,
                                 properties: [String: VectorTile_Tile.Value] = [:],
                                 zoom: Int = 10) -> Float {
        let style = makeStyle(layerName: layerName, properties: properties, zoom: zoom)
        guard let labelTextStyle = style.labelTextStyle else {
            XCTFail("Expected base label style for \(layerName)")
            return -1
        }
        return labelTextStyle.haloEm
    }

    private func baseLabelSizePoints(layerName: String,
                                     properties: [String: VectorTile_Tile.Value] = [:],
                                     zoom: Int = 10) -> Float {
        let style = makeStyle(layerName: layerName, properties: properties, zoom: zoom)
        guard let labelTextStyle = style.labelTextStyle else {
            XCTFail("Expected base label style for \(layerName)")
            return -1
        }
        return labelTextStyle.sizePoints
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
