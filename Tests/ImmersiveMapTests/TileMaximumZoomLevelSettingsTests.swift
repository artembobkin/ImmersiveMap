// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileMaximumZoomLevelSettingsTests: XCTestCase {
    /// The default depth is the hosted service's: a bare map never asks the
    /// hosted source for tiles it does not serve.
    func testDefaultDepthMatchesTheHostedService() {
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.coverage.maximumZoomLevel,
                       ImmersiveMapTilesService.maximumTileZoomLevel)
    }

    /// A source built deeper than the hosted default states its depth with one
    /// modifier next to its URL template.
    func testModifierRaisesTheRequestedTileDepth() {
        let settings = ImmersiveMapSettings.default.tileMaximumZoomLevel(16)
        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel, 16)

        let view = ImmersiveMapView().tileMaximumZoomLevel(16)
        XCTAssertEqual(view.settings.tiles.coverage.maximumZoomLevel, 16)
    }

    /// The coverage resolution follows the raised cap: the camera between the
    /// old and the new depth gets native tiles, and past the cap the deepest
    /// level holds.
    func testCoverageResolutionHonorsTheRaisedCap() {
        let tiles = ImmersiveMapSettings.default.tileMaximumZoomLevel(16).tiles

        XCTAssertEqual(tiles.resolvedCoverageZoomLevel(forCameraZoom: 15.4), 15)
        XCTAssertEqual(tiles.resolvedCoverageZoomLevel(forCameraZoom: 16.0), 16)
        XCTAssertEqual(tiles.resolvedCoverageZoomLevel(forCameraZoom: 18.7), 16)

        let defaultTiles = ImmersiveMapSettings.default.tiles
        XCTAssertEqual(defaultTiles.resolvedCoverageZoomLevel(forCameraZoom: 18.7),
                       ImmersiveMapTilesService.maximumTileZoomLevel,
                       "Without the modifier the hosted depth stays the ceiling")
    }
}
