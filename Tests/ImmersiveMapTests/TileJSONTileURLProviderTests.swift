// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

final class TileJSONTileURLProviderTests: XCTestCase {
    // MARK: - Template loader

    func testLoaderExtractsFirstTileTemplate() async throws {
        let json = #"{"tiles":["https://tiles.immersivemap.dev/v/abc-def/tiles/{z}/{x}/{y}.pbf"],"minzoom":0}"#
        let loader = TileJSONTemplateLoader(loadData: { _ in Data(json.utf8) })
        let template = try await loader.loadTemplate(from: URL(string: "https://tiles.immersivemap.dev/tiles.json")!)
        XCTAssertEqual(template, "https://tiles.immersivemap.dev/v/abc-def/tiles/{z}/{x}/{y}.pbf")
    }

    func testLoaderReturnsNilWhenNoTiles() async throws {
        let loader = TileJSONTemplateLoader(loadData: { _ in Data(#"{"tiles":[]}"#.utf8) })
        let template = try await loader.loadTemplate(from: URL(string: "https://example.com/tiles.json")!)
        XCTAssertNil(template)
    }

    // MARK: - URL building from a template

    func testURLFromTemplateSubstitutesCoordinates() {
        let url = TileJSONTileURLProvider.url(
            fromTemplate: "https://host/v/abc-def/tiles/{z}/{x}/{y}.pbf",
            x: 3, y: 5, z: 4)
        XCTAssertEqual(url?.absoluteString, "https://host/v/abc-def/tiles/4/3/5.pbf")
    }

    // MARK: - Provider fallback then upgrade

    func testProviderFallsBackToBaseUntilTemplateResolves() {
        let store = TileJSONTemplateStore()
        let fallback = BackendTileURLProvider(baseURL: URL(string: "https://host/tiles")!)
        let provider = TileJSONTileURLProvider(fallback: fallback, store: store)

        // No template yet -> legacy base path (.mvt), so rendering is never blocked.
        XCTAssertEqual(provider.get(tileX: 1, tileY: 2, tileZ: 3).absoluteString,
                       "https://host/tiles/3/1/2.mvt")

        // Template resolved -> versioned, immutable path (.pbf) served over the CDN.
        store.update("https://host/v/ver/tiles/{z}/{x}/{y}.pbf")
        XCTAssertEqual(provider.get(tileX: 1, tileY: 2, tileZ: 3).absoluteString,
                       "https://host/v/ver/tiles/3/1/2.pbf")
    }

    // MARK: - Source wiring

    func testDefaultSettingsPointAtTheHostedTileJSONNextToTheTilePath() {
        let network = ImmersiveMapSettings.default.tiles.network
        XCTAssertEqual(network.tileBaseURL, ImmersiveMapTilesService.tileBaseURL)
        XCTAssertEqual(network.tileJSONURL?.absoluteString,
                       "https://tiles.immersivemap.dev/tiles.json")
    }
}
