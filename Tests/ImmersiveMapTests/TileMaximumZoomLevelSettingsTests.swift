// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// `@MainActor` like every other suite that builds an `ImmersiveMapView`: the
/// view is a SwiftUI `View` and so main-actor isolated, and reaching it from a
/// nonisolated test is an error under the Swift 6.1 toolchain CI runs.
@MainActor
final class TileMaximumZoomLevelSettingsTests: XCTestCase {
    /// The default depth is the hosted service's: a bare map never asks the
    /// hosted source for tiles it does not serve.
    func testDefaultDepthMatchesTheHostedService() {
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.coverage.maximumZoomLevel,
                       ImmersiveMapTilesService.maximumTileZoomLevel)
    }

    /// A source built to a different depth than the default states it with
    /// one modifier next to its URL template, in either direction.
    func testModifierStatesTheSourceDepth() {
        let shallower = ImmersiveMapSettings.default.tileMaximumZoomLevel(14)
        XCTAssertEqual(shallower.tiles.coverage.maximumZoomLevel, 14)

        let view = ImmersiveMapView().tileMaximumZoomLevel(18)
        XCTAssertEqual(view.settings.tiles.coverage.maximumZoomLevel, 18)
    }

    /// The coverage resolution follows the stated depth: the camera below it
    /// gets native tiles, and past it the deepest level holds.
    func testCoverageResolutionHonorsTheStatedDepth() {
        let defaultTiles = ImmersiveMapSettings.default.tiles
        XCTAssertEqual(defaultTiles.resolvedCoverageZoomLevel(forCameraZoom: 15.4), 15)
        XCTAssertEqual(defaultTiles.resolvedCoverageZoomLevel(forCameraZoom: 16.0), 16)
        XCTAssertEqual(defaultTiles.resolvedCoverageZoomLevel(forCameraZoom: 18.7),
                       ImmersiveMapTilesService.maximumTileZoomLevel,
                       "The default ceiling is the hosted depth")

        let shallowTiles = ImmersiveMapSettings.default.tileMaximumZoomLevel(14).tiles
        XCTAssertEqual(shallowTiles.resolvedCoverageZoomLevel(forCameraZoom: 18.7), 14,
                       "A shallower source is never asked past its depth")
    }
}
