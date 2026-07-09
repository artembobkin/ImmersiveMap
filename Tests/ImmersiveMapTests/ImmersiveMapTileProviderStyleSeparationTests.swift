// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapTileProviderStyleSeparationTests: XCTestCase {
    func testSettingsDoNotKeepLegacyCombinedProviderState() {
        let settings = ImmersiveMapSettings.default

        let settingLabels = Mirror(reflecting: settings).children.compactMap(\.label)

        XCTAssertFalse(settingLabels.contains("provider"))
    }

    func testTileProviderConfiguresSourceAndTechnicalLabelProfileSeparatelyFromStyle() {
        let tileProvider = VectorTileProvider(
            id: "custom-tiles",
            tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!),
            labelProfile: ImmersiveMapVectorTileLabelProfile(textKeys: ["title"]),
            maximumTileZoomLevel: 16
        )
        let mapStyle = VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 77))

        let settings = ImmersiveMapSettings.default
            .tileProvider(tileProvider)
            .mapStyle(mapStyle)

        XCTAssertEqual(settings.tileProvider.id, "custom-tiles")
        XCTAssertEqual(settings.tileProvider.tileSource.tileBaseURL.absoluteString,
                       "https://example.com/api/v1/map/tiles")
        XCTAssertEqual(settings.tiles.network.tileBaseURL.absoluteString,
                       "https://example.com/api/v1/map/tiles")
        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel, 16)
        XCTAssertEqual(settings.mapStyle.configurationFingerprint, mapStyle.configurationFingerprint)

        let runtime = ImmersiveMapProviderRuntimeContext(settings: settings)
        XCTAssertEqual(runtime.mapStyle.preparedTileStyleRevision, 77)
        XCTAssertEqual(runtime.labelProviderProfile.providerID, "custom-tiles")
        XCTAssertEqual(runtime.labelProviderProfile.labelTextKeys, ["title"])
    }

    func testChangingOnlyMapStyleIsAStyleChangeNotATileSourceChange() {
        let tileProvider = VectorTileProvider(
            id: "custom-tiles",
            tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!)
        )
        let oldSettings = ImmersiveMapSettings.default
            .tileProvider(tileProvider)
            .mapStyle(VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 1)))
        let newSettings = ImmersiveMapSettings.default
            .tileProvider(tileProvider)
            .mapStyle(VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 2)))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
    }

    func testChangingOnlyTileProviderIsATileChange() {
        let oldSettings = ImmersiveMapSettings.default
            .tileProvider(VectorTileProvider(
                id: "custom-tiles",
                tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!)
            ))
            .mapStyle(VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 1)))
        let newSettings = ImmersiveMapSettings.default
            .tileProvider(VectorTileProvider(
                id: "custom-tiles",
                tileSource: .url(URL(string: "https://example.com/api/v2/map/tiles")!)
            ))
            .mapStyle(VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 1)))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.tiles])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .recreateRenderer])
    }
}
