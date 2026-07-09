// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class MapboxDefaultMapStyleLayerColorTests: XCTestCase {
    func testCustomLayerColorsControlWaterAndLanduseFills() {
        let configuration = styleConfiguration { layers in
            layers.water = SIMD4<Float>(0.1, 0.2, 0.3, 1.0)
            layers.park = SIMD4<Float>(0.2, 0.5, 0.25, 0.8)
            layers.residential = SIMD4<Float>(0.8, 0.7, 0.6, 0.5)
            layers.industrial = SIMD4<Float>(0.45, 0.46, 0.47, 0.75)
        }

        XCTAssertEqual(makeStyle(layerName: "water",
                                 properties: [:],
                                 configuration: configuration).color,
                       SIMD4<Float>(0.1, 0.2, 0.3, 1.0))
        XCTAssertEqual(makeStyle(layerName: "landuse",
                                 properties: ["class": stringValue("park")],
                                 configuration: configuration).color,
                       SIMD4<Float>(0.2, 0.5, 0.25, 0.8))
        XCTAssertEqual(makeStyle(layerName: "landuse",
                                 properties: ["class": stringValue("residential")],
                                 configuration: configuration).color,
                       SIMD4<Float>(0.8, 0.7, 0.6, 0.5))
        XCTAssertEqual(makeStyle(layerName: "landuse",
                                 properties: ["class": stringValue("industrial")],
                                 configuration: configuration).color,
                       SIMD4<Float>(0.45, 0.46, 0.47, 0.75))
    }

    func testCustomRoadLayerColorControlsMajorRoadFill() {
        let configuration = styleConfiguration { layers in
            layers.roads.major = SIMD4<Float>(0.75, 0.45, 0.35, 1.0)
        }

        let style = makeStyle(layerName: "road",
                              properties: ["class": stringValue("primary")],
                              configuration: configuration)

        XCTAssertEqual(style.color, SIMD4<Float>(0.75, 0.45, 0.35, 1.0))
        XCTAssertEqual(style.resolvedLineRenderPasses.last?.color,
                       SIMD4<Float>(0.75, 0.45, 0.35, 1.0))
    }

    func testDefaultLayerTokensPreserveBaseWaterColorOverride() {
        var styleSettings = ImmersiveMapSettings.default.style
        styleSettings.baseColors = .init(
            tileBackground: SIMD4<Float>(0.98, 0.98, 0.96, 1.0),
            globeBackground: SIMD4<Double>(0.0039, 0.0431, 0.0980, 1.0),
            water: SIMD4<Float>(0.25, 0.35, 0.45, 1.0),
            landCover: SIMD4<Float>(0.45, 0.65, 0.45, 0.7)
        )

        XCTAssertEqual(makeStyle(layerName: "water",
                                 properties: [:],
                                 styleSettings: styleSettings).color,
                       SIMD4<Float>(0.25, 0.35, 0.45, 1.0))
        XCTAssertEqual(makeStyle(layerName: "landuse",
                                 properties: ["class": stringValue("grass")],
                                 styleSettings: styleSettings).color,
                       SIMD4<Float>(0.45, 0.65, 0.45, 0.7))
    }

    func testContourLayerIsHiddenAtTerrainZooms() {
        let style = makeStyle(layerName: "contour",
                              properties: [:],
                              tile: Tile(x: 618, y: 320, z: 10))

        XCTAssertEqual(style.key, 0)
    }

    func testLayerUpdatesChangeCacheFingerprint() {
        let original = MapboxDefaultMapStyleConfiguration.mapboxDefault
        let updated = original.layers { layers in
            layers.water = SIMD4<Float>(0.1, 0.2, 0.3, 1.0)
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
    }

    private func styleConfiguration(_ update: (inout MapboxDefaultMapStyleConfiguration.LayerStyles) -> Void)
        -> MapboxDefaultMapStyleConfiguration {
        .mapboxDefault.layers(update)
    }

    private func makeStyle(layerName: String,
                           properties: [String: VectorTile_Tile.Value],
                           tile: Tile = Tile(x: 0, y: 0, z: 14),
                           configuration: MapboxDefaultMapStyleConfiguration = .mapboxDefault,
                           styleSettings: ImmersiveMapSettings.StyleSettings = ImmersiveMapSettings.default.style) -> FeatureStyle {
        MapboxDefaultMapStyle(configuration: configuration,
                              settings: styleSettings).makeStyle(
            data: DetFeatureStyleData(layerName: layerName,
                                      properties: properties,
                                      tile: tile)
        )
    }

    private func stringValue(_ value: String) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.stringValue = value
        return tileValue
    }
}
