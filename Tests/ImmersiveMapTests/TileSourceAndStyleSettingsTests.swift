// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileSourceAndStyleSettingsTests: XCTestCase {
    func testArchiveAndMapStyleConfigureSourceAndStyleSeparately() {
        let style = ProtomapsBasemapTheme.default.labels { labels in
            labels.town.haloEm = 0.125
        }

        let settings = ImmersiveMapSettings.default
            .tileArchive(URL(string: "https://tiles.example.com/planet.pmtiles")!)
            .mapStyle(ProtomapsBasemapMapStyle(theme: style))

        XCTAssertEqual(settings.tiles.network.tileArchiveURL,
                       URL(string: "https://tiles.example.com/planet.pmtiles"))
        XCTAssertEqual(settings.mapStyle.configurationFingerprint,
                       AnyImmersiveMapMapStyle(ProtomapsBasemapMapStyle(theme: style)).configurationFingerprint)
        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel,
                       ImmersiveMapTilesService.maximumTileZoomLevel)
    }

    func testDefaultSettingsPointAtTheHostedService() {
        let network = ImmersiveMapSettings.default.tiles.network

        XCTAssertEqual(network.tileArchiveURL, ImmersiveMapTilesService.tileArchiveURL)
        XCTAssertEqual(network.tileArchiveURL.pathExtension, "pmtiles")
        XCTAssertTrue(network.tileRequestHeaders.isEmpty)
        XCTAssertNotEqual(network.cacheIdentity, 0)
    }

    func testMapStyleChangeRebuildsPreparedData() {
        let oldSettings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle(theme: .default))
        let newSettings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle(theme: .default.layers { layers in
                layers.water = SIMD4<Float>(0.12, 0.34, 0.56, 1.0)
            }))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }

    /// The overview is laid into the tiles by the load pipeline, built with
    /// the renderer, and baked into the prepared tiles: switching it
    /// rebuilds both.
    func testOverviewTilesChangeRebuildsThePipelineAndThePreparedData() {
        let oldSettings = ImmersiveMapSettings.default
        XCTAssertTrue(oldSettings.tiles.overview.isEnabled, "The overview is on by default")
        let newSettings = oldSettings.overviewTiles(isEnabled: false)

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.tiles, .attribution],
                       "The overview's credit leaves the badge with the overview")
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .recreateRenderer, .liveApply])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }
}
