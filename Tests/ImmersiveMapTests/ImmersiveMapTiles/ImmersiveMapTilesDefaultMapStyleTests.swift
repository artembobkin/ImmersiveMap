// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapTilesDefaultMapStyleTests: XCTestCase {
    func testSoftBiomesPalettePaintsOverviewBaseOnlyThroughZoomNine() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: configuration)

        XCTAssertEqual(makeStyle(style, layerName: "background", zoom: 2).color,
                       configuration.globalLandcover.grass)
        XCTAssertEqual(makeStyle(style, layerName: "background", zoom: 9).color,
                       configuration.globalLandcover.land)
        XCTAssertEqual(makeStyle(style, layerName: "water", zoom: 9).color,
                       configuration.globalLandcover.water)
        XCTAssertEqual(makeStyle(style, layerName: "background", zoom: 10).color,
                       configuration.layers.land)
        XCTAssertEqual(makeStyle(style, layerName: "water", zoom: 10).color,
                       configuration.layers.water)
    }

    func testMassiveOverviewMergesVegetationClassesThroughZoomTwo() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let colors = configuration.globalLandcover
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: configuration)
        let mergedClasses = ["land", "grass", "shrub", "moss", "crop", "wetland", "mangroves"]

        for className in mergedClasses {
            XCTAssertEqual(makeStyle(style,
                                     layerName: "globallandcover",
                                     className: className,
                                     zoom: 2).color,
                           colors.grass,
                           "Expected massive overview color for \(className)")
        }

        let overviewForest = colors.grass + (colors.forest - colors.grass) * 0.25
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "forest",
                                 zoom: 2).color,
                       overviewForest)
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "land",
                                 zoom: 3).color,
                       colors.land)
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "crop",
                                 zoom: 3).color,
                       colors.crop)
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "forest",
                                 zoom: 3).color,
                       colors.forest)
    }

    func testGlobalLandcoverClassesUseDedicatedSoftBiomesColors() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let colors = configuration.globalLandcover
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: configuration)
        let expected: [(String, UInt8, SIMD4<Float>)] = [
            ("land", 2, colors.land),
            ("barren", 3, colors.barren),
            ("grass", 4, colors.grass),
            ("shrub", 4, colors.grass),
            ("moss", 4, colors.grass),
            ("crop", 5, colors.crop),
            ("forest", 6, colors.forest),
            ("wetland", 7, colors.wetland),
            ("mangroves", 7, colors.wetland),
            ("snow", 8, colors.snow)
        ]

        for (className, key, color) in expected {
            let featureStyle = makeStyle(style,
                                         layerName: "globallandcover",
                                         className: className,
                                         zoom: 5)
            XCTAssertEqual(featureStyle.key, key, "Unexpected key for \(className)")
            XCTAssertEqual(featureStyle.color, color, "Unexpected color for \(className)")
        }
    }

    func testGlobalPaletteUpdateChangesPreparedTileRevision() {
        let originalConfiguration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let updatedConfiguration = originalConfiguration.globalLandcover { colors in
            colors.water = SIMD4<Float>(0.1, 0.2, 0.3, 1.0)
        }

        XCTAssertNotEqual(originalConfiguration.cacheFingerprint,
                          updatedConfiguration.cacheFingerprint)
        XCTAssertNotEqual(ImmersiveMapTilesDefaultMapStyle(configuration: originalConfiguration)
                            .preparedTileStyleRevision,
                          ImmersiveMapTilesDefaultMapStyle(configuration: updatedConfiguration)
                            .preparedTileStyleRevision)
    }

    func testIconlessPoiCarriesConfiguredMinCameraZoom() {
        // default labelVisibility.poiIconlessMinimumZoom == 16
        let style = ImmersiveMapTilesDefaultMapStyle(
            configuration: .immersiveMapTilesDefault
        )

        // Iconless POI (class "office" вне набора иконок): лейбл присутствует в
        // prepared-тайле, но несёт порог minCameraZoom == 16. Видимость решается
        // в рантайме по зуму камеры, поэтому tile.z здесь роли не играет.
        let officeStyle = makeStyle(style, layerName: "poi", className: "office", zoom: 14)
        XCTAssertNotNil(officeStyle.labelTextStyle)
        XCTAssertEqual(officeStyle.labelMinCameraZoom, 16)

        // Iconful POI (class "shop" -> иконка shopping): порога нет, виден всегда.
        let shopStyle = makeStyle(style, layerName: "poi", className: "shop", zoom: 14)
        XCTAssertNotNil(shopStyle.labelTextStyle)
        XCTAssertEqual(shopStyle.labelMinCameraZoom, 0)
    }

    func testIconlessPoiZoomChangesPreparedTileRevision() {
        let original = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let updated = original.labelVisibility { visibility in
            visibility.poiIconlessMinimumZoom = 14
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
        XCTAssertNotEqual(ImmersiveMapTilesDefaultMapStyle(configuration: original).preparedTileStyleRevision,
                          ImmersiveMapTilesDefaultMapStyle(configuration: updated).preparedTileStyleRevision)
    }

    private func makeStyle(_ style: ImmersiveMapTilesDefaultMapStyle,
                           layerName: String,
                           className: String? = nil,
                           zoom: Int) -> FeatureStyle {
        var properties: [String: VectorTile_Tile.Value] = [:]
        if let className {
            properties["class"] = stringValue(className)
        }
        return style.makeStyle(
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
}
