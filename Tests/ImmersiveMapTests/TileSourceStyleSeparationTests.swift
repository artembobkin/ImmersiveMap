// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The tile source and the map style are independent settings: the source is
/// only a URL bytes come from, and everything about interpreting them (style,
/// label profile) is configured on the style side.
final class TileSourceStyleSeparationTests: XCTestCase {
    func testSettingsDoNotKeepLegacyCombinedProviderState() {
        let settings = ImmersiveMapSettings.default

        let settingLabels = Mirror(reflecting: settings).children.compactMap(\.label)

        XCTAssertFalse(settingLabels.contains("provider"))
        XCTAssertFalse(settingLabels.contains("tileProvider"))
    }

    func testTemplateConfiguresSourceAndStyleConfiguresParsingSeparately() {
        let mapStyle = VectorTileMapStyle(style: TitledVectorTileStyle(cacheFingerprint: 77))

        let settings = ImmersiveMapSettings.default
            .tileURLTemplate("https://example.com/api/v1/map/tiles/{z}/{x}/{y}.mvt")
            .mapStyle(mapStyle)

        XCTAssertEqual(settings.tiles.network.tileURLTemplate,
                       "https://example.com/api/v1/map/tiles/{z}/{x}/{y}.mvt")
        XCTAssertEqual(settings.mapStyle.configurationFingerprint, mapStyle.configurationFingerprint)

        let runtime = MapStyleRuntime(settings: settings)
        XCTAssertEqual(runtime.style.cacheFingerprint, 77)
        XCTAssertEqual(runtime.styleID, AnyImmersiveMapMapStyle.genericStyleID)
        XCTAssertEqual(runtime.style.labelTextKeys, ["title"])
    }

    func testChangingOnlyMapStyleIsAStyleChangeNotATileSourceChange() {
        let oldSettings = ImmersiveMapSettings.default
            .tileURLTemplate("https://example.com/tiles/{z}/{x}/{y}.mvt")
            .mapStyle(VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 1)))
        let newSettings = ImmersiveMapSettings.default
            .tileURLTemplate("https://example.com/tiles/{z}/{x}/{y}.mvt")
            .mapStyle(VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 2)))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
    }

    func testChangingOnlyTheTemplateIsATileChange() {
        let oldSettings = ImmersiveMapSettings.default
            .tileURLTemplate("https://example.com/api/v1/map/tiles/{z}/{x}/{y}.mvt")
            .mapStyle(VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 1)))
        let newSettings = ImmersiveMapSettings.default
            .tileURLTemplate("https://example.com/api/v2/map/tiles/{z}/{x}/{y}.mvt")
            .mapStyle(VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 1)))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.tiles])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .recreateRenderer])
    }
}

/// A one-colour style whose labels read their text from `title`.
private struct TitledVectorTileStyle: ImmersiveMapVectorTileStyle {
    let cacheFingerprint: UInt32
    let labelTextKeys = ["title"]

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        .polygon(key: 2, color: SIMD4<Float>(1, 0, 0, 1))
    }
}
