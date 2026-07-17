// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapProviderSettingsTests: XCTestCase {
    func testMapboxTileProviderAndMapStyleConfigureSourceAndStyleSeparately() {
        let style = MapboxDefaultMapStyleConfiguration.mapboxDefault.labels { labels in
            labels.district.strokeWidthPx = 1.25
        }

        let settings = ImmersiveMapSettings.default
            .tileProvider(MapboxTileProvider(accessToken: "mapbox-token"))
            .mapStyle(MapboxMapStyle(configuration: style))

        XCTAssertEqual(settings.tileProvider.id, "mapbox")
        XCTAssertEqual(settings.tileProvider.cacheNamespace, "mapbox")
        XCTAssertEqual(settings.tiles.network.tileBaseURL.absoluteString,
                       "https://api.mapbox.com/v4/mapbox.mapbox-streets-v8,mapbox.mapbox-terrain-v2")
        XCTAssertEqual(settings.tiles.network.authorizationToken, "mapbox-token")
        XCTAssertEqual(settings.tiles.network.authorizationMode, .accessTokenQuery(parameterName: "access_token"))
        XCTAssertEqual(settings.mapStyle.configurationFingerprint,
                       AnyImmersiveMapMapStyle(MapboxMapStyle(configuration: style)).configurationFingerprint)
        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel, 20)
    }

    func testMapboxTileProviderRestoresDefaultMaximumZoomAfterCustomTileProvider() {
        let settings = ImmersiveMapSettings.default
            .tileProvider(VectorTileProvider(
                id: "example",
                tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!),
                maximumTileZoomLevel: 12
            ))
            .tileProvider(MapboxTileProvider(accessToken: nil))

        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel, 20)
    }

    func testMapStyleChangeRebuildsPreparedData() {
        let oldSettings = ImmersiveMapSettings.default
            .tileProvider(MapboxTileProvider(accessToken: "mapbox-token"))
            .mapStyle(MapboxMapStyle(configuration: .mapboxDefault))
        let newSettings = ImmersiveMapSettings.default
            .tileProvider(MapboxTileProvider(accessToken: "mapbox-token"))
            .mapStyle(MapboxMapStyle(configuration: .mapboxDefault.layers { layers in
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
