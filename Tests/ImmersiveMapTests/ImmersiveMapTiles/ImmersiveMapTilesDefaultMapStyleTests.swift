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
        // Appearance threshold = tile.z + log4(effRank / budget): the cell
        // budget quadruples per overzoom zoom level. There are no absolute zoom
        // ramps, so the approach survives a change of the source's maxzoom.
        let style = ImmersiveMapTilesDefaultMapStyle(
            configuration: .immersiveMapTilesDefault
        )

        // Anchor (hospital): the negative offset is clamped into the budget,
        // visible from the tile's birth regardless of rank.
        let hospitalStyle = makeStyle(style, layerName: "poi", className: "hospital", rank: 20, zoom: 14)
        XCTAssertEqual(hospitalStyle.labelMinCameraZoom, 14)

        // Neutral commerce (shop, rank 2): log4(2) = 0.5 zoom of overzoom.
        let shopStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 2, zoom: 14)
        XCTAssertEqual(shopStyle.labelMinCameraZoom, 14.5, accuracy: 0.001)

        // The rank tail arrives later: log4(20) ~ 2.16 zooms.
        let deepRankStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 20, zoom: 14)
        XCTAssertEqual(deepRankStyle.labelMinCameraZoom, 14 + log2(Float(20)) / 2, accuracy: 0.001)

        // Infrastructure (bus, rank 2): offset +40 -> log4(42) ~ 2.7 zooms.
        let busStyle = makeStyle(style, layerName: "poi", className: "bus", rank: 2, zoom: 14)
        XCTAssertEqual(busStyle.labelMinCameraZoom, 14 + log2(Float(42)) / 2, accuracy: 0.001)

        // Iconless POI (class "office" outside the icon set): the configurable
        // iconless threshold (16) remains the lower bound.
        let officeStyle = makeStyle(style, layerName: "poi", className: "office", rank: 2, zoom: 14)
        XCTAssertEqual(officeStyle.labelMinCameraZoom, 16)

        // Zoom agnosticism: the same shop in a z13 tile appears one zoom earlier.
        let earlierTileStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 2, zoom: 13)
        XCTAssertEqual(earlierTileStyle.labelMinCameraZoom, 13.5, accuracy: 0.001)
    }

    func testPoiMinimumZoomFloorsEveryPoiAboveRankAndOverzoomThresholds() {
        let style = ImmersiveMapTilesDefaultMapStyle(
            configuration: .immersiveMapTilesDefault.labelVisibility { visibility in
                visibility.poiMinimumZoom = 30
            }
        )

        // The floor wins over both the from-birth anchor threshold and the
        // overzoom-delay cap (tile.z + 3.5), so a value above the camera's
        // maximum zoom hides POIs entirely.
        let hospitalStyle = makeStyle(style, layerName: "poi", className: "hospital", rank: 20, zoom: 14)
        XCTAssertEqual(hospitalStyle.labelMinCameraZoom, 30)
        let shopStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 2, zoom: 14)
        XCTAssertEqual(shopStyle.labelMinCameraZoom, 30)
    }

    func testPoiMinimumZoomChangesPreparedTileRevision() {
        let original = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let updated = original.labelVisibility { visibility in
            visibility.poiMinimumZoom = 30
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
        XCTAssertNotEqual(ImmersiveMapTilesDefaultMapStyle(configuration: original).preparedTileStyleRevision,
                          ImmersiveMapTilesDefaultMapStyle(configuration: updated).preparedTileStyleRevision)
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

        // Boundaries are a line style: areal geometry (e.g. Native American
        // reservations arriving as polygons) must not be filled.
        XCTAssertTrue(makeStyle(style, layerName: "boundary", zoom: 6).suppressPolygonFill)

        // Regular areal layers still fill polygons as before.
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
