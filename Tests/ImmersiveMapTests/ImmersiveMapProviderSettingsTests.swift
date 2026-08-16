// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapProviderSettingsTests: XCTestCase {
    func testTemplateAndMapStyleConfigureSourceAndStyleSeparately() {
        let style = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.labels { labels in
            labels.town.haloEm = 0.125
        }

        let settings = ImmersiveMapSettings.default
            .tileURLTemplate("https://tiles.example.com/tiles/{z}/{x}/{y}.mvt")
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: style))

        XCTAssertEqual(settings.tiles.network.tileURLTemplate,
                       "https://tiles.example.com/tiles/{z}/{x}/{y}.mvt")
        XCTAssertEqual(settings.mapStyle.configurationFingerprint,
                       AnyImmersiveMapMapStyle(ImmersiveMapTilesMapStyle(configuration: style)).configurationFingerprint)
        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel,
                       ImmersiveMapTilesService.maximumTileZoomLevel)
    }

    func testDefaultSettingsPointAtTheHostedService() {
        let network = ImmersiveMapSettings.default.tiles.network

        XCTAssertEqual(network.tileBaseURL, ImmersiveMapTilesService.tileBaseURL)
        XCTAssertEqual(network.tileJSONURL, ImmersiveMapTilesService.tileJSONURL)
        XCTAssertNil(network.tileURLTemplate)
        XCTAssertTrue(network.tileRequestHeaders.isEmpty)
        XCTAssertNotEqual(network.cacheIdentity, 0)
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
}
