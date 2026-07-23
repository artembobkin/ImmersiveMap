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

    func testPoiMinCameraZoomDerivesFromOverzoomBudgetAndPriorities() {
        // Порог появления = tile.z + log4(effRank / бюджет): бюджет клетки
        // учетверяется за зум оверзума. Абсолютных зум-рамп нет, поэтому
        // подход переживает смену maxzoom источника.
        let style = ImmersiveMapTilesDefaultMapStyle(
            configuration: .immersiveMapTilesDefault
        )

        // Якорь (hospital): отрицательное смещение клампится в бюджет, виден
        // с рождения тайла независимо от ранга.
        let hospitalStyle = makeStyle(style, layerName: "poi", className: "hospital", rank: 20, zoom: 14)
        XCTAssertEqual(hospitalStyle.labelMinCameraZoom, 14)

        // Нейтральная коммерция (shop, rank 2): log4(2) = 0.5 зума оверзума.
        let shopStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 2, zoom: 14)
        XCTAssertEqual(shopStyle.labelMinCameraZoom, 14.5, accuracy: 0.001)

        // Хвост ранга приходит позже: log4(20) ~ 2.16 зума.
        let deepRankStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 20, zoom: 14)
        XCTAssertEqual(deepRankStyle.labelMinCameraZoom, 14 + log2(Float(20)) / 2, accuracy: 0.001)

        // Инфраструктура (bus, rank 2): смещение +40 -> log4(42) ~ 2.7 зума.
        let busStyle = makeStyle(style, layerName: "poi", className: "bus", rank: 2, zoom: 14)
        XCTAssertEqual(busStyle.labelMinCameraZoom, 14 + log2(Float(42)) / 2, accuracy: 0.001)

        // Iconless POI (class "office" вне набора иконок): конфигурируемый
        // порог безыконных (16) остаётся нижней границей.
        let officeStyle = makeStyle(style, layerName: "poi", className: "office", rank: 2, zoom: 14)
        XCTAssertEqual(officeStyle.labelMinCameraZoom, 16)

        // Зум-агностичность: тот же shop в тайле z13 появляется на зум раньше.
        let earlierTileStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 2, zoom: 13)
        XCTAssertEqual(earlierTileStyle.labelMinCameraZoom, 13.5, accuracy: 0.001)
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

    func testBoundaryStyleSuppressesPolygonFill() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

        // Границы - линейный стиль: площадную геометрию (напр. индейские
        // резервации, приходящие полигонами) заливать нельзя.
        XCTAssertTrue(makeStyle(style, layerName: "boundary", zoom: 6).suppressPolygonFill)

        // Обычные площадные слои полигоны заливают как прежде.
        XCTAssertFalse(makeStyle(style, layerName: "water", zoom: 6).suppressPolygonFill)
    }

    private func makeStyle(_ style: ImmersiveMapTilesDefaultMapStyle,
                           layerName: String,
                           className: String? = nil,
                           rank: Int? = nil,
                           zoom: Int) -> FeatureStyle {
        var properties: [String: VectorTile_Tile.Value] = [:]
        if let className {
            properties["class"] = stringValue(className)
        }
        if let rank {
            var rankValue = VectorTile_Tile.Value()
            rankValue.intValue = Int64(rank)
            properties["rank"] = rankValue
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
