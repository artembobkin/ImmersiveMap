// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapProviderSettingsTests: XCTestCase {
    func testBuiltInTileProviderAndMapStyleConfigureSourceAndStyleSeparately() {
        let style = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.labels { labels in
            labels.town.haloEm = 0.125
        }

        // A non-default base URL, so the assertion proves the provider was copied
        // into `tiles.network` rather than matching what `.default` already held.
        let tileBaseURL = URL(string: "https://tiles.example.com/tiles")!
        let settings = ImmersiveMapSettings.default
            .tileProvider(ImmersiveMapTilesProvider(tileBaseURL: tileBaseURL, apiKey: "tiles-key"))
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: style))

        XCTAssertNotEqual(tileBaseURL, ImmersiveMapTilesProvider.defaultTileBaseURL)
        XCTAssertEqual(settings.tileProvider.id, "immersivemaptiles")
        XCTAssertEqual(settings.tileProvider.cacheNamespace, "immersivemaptiles")
        XCTAssertEqual(settings.tiles.network.tileBaseURL, tileBaseURL)
        XCTAssertEqual(settings.tiles.network.authorizationToken, "tiles-key")
        XCTAssertEqual(settings.tiles.network.authorizationMode, .bearerHeader)
        XCTAssertEqual(settings.mapStyle.configurationFingerprint,
                       AnyImmersiveMapMapStyle(ImmersiveMapTilesMapStyle(configuration: style)).configurationFingerprint)
        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel, ImmersiveMapTilesProvider.defaultMaximumTileZoomLevel)
    }

    func testBuiltInTileProviderRestoresDefaultMaximumZoomAfterCustomTileProvider() {
        let settings = ImmersiveMapSettings.default
            .tileProvider(VectorTileProvider(
                id: "example",
                tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!),
                maximumTileZoomLevel: 12
            ))
            .tileProvider(ImmersiveMapTilesProvider())

        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel, ImmersiveMapTilesProvider.defaultMaximumTileZoomLevel)
    }

    func testMapStyleChangeRebuildsPreparedData() {
        let oldSettings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: .immersiveMapTilesDefault))
        let newSettings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: .immersiveMapTilesDefault.layers { layers in
                layers.water = SIMD4<Float>(0.12, 0.34, 0.56, 1.0)
            }))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }

    func testVectorTileProviderCanConfigureMaximumTileZoomLevel() {
        let settings = ImmersiveMapSettings.default.tileProvider(
            VectorTileProvider(
                id: "example",
                tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!),
                maximumTileZoomLevel: 12
            )
        )

        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel, 12)
    }

}
