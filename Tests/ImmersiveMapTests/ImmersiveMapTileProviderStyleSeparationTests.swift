// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The tile source and the map style are independent settings: the source is
/// only a URL bytes come from, and everything about interpreting them (style,
/// label profile) is configured on the style side.
final class ImmersiveMapTileProviderStyleSeparationTests: XCTestCase {
    func testSettingsDoNotKeepLegacyCombinedProviderState() {
        let settings = ImmersiveMapSettings.default

        let settingLabels = Mirror(reflecting: settings).children.compactMap(\.label)

        XCTAssertFalse(settingLabels.contains("provider"))
        XCTAssertFalse(settingLabels.contains("tileProvider"))
    }

    func testTemplateConfiguresSourceAndStyleConfiguresParsingSeparately() {
        let mapStyle = VectorTileMapStyle(
            style: BasicVectorTileStyle(cacheFingerprint: 77),
            labelProfile: ImmersiveMapVectorTileLabelProfile(textKeys: ["title"]))

        let settings = ImmersiveMapSettings.default
            .tileURLTemplate("https://example.com/api/v1/map/tiles/{z}/{x}/{y}.mvt")
            .mapStyle(mapStyle)

        XCTAssertEqual(settings.tiles.network.tileURLTemplate,
                       "https://example.com/api/v1/map/tiles/{z}/{x}/{y}.mvt")
        XCTAssertEqual(settings.mapStyle.configurationFingerprint, mapStyle.configurationFingerprint)

        let runtime = ImmersiveMapProviderRuntimeContext(settings: settings)
        XCTAssertEqual(runtime.mapStyle.preparedTileStyleRevision, 77)
        XCTAssertEqual(runtime.labelProviderProfile.providerID, AnyImmersiveMapMapStyle.genericStyleID)
        XCTAssertEqual(runtime.labelProviderProfile.labelTextKeys, ["title"])
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
