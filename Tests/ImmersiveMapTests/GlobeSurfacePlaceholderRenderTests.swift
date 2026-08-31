// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The globe paints its own surface before any tile arrives, so the very first
/// frame shows a planet in the map's background color instead of a shell with
/// space showing through it. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class GlobeSurfacePlaceholderRenderTests: XCTestCase {
    @MainActor
    func testFirstGlobeFrameIsOpaqueBeforeAnyTileArrives() async throws {
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: .default.earthScene(isEnabled: false))
        harness.setZoom(1.0)

        let center = try await harness.renderFrame().center

        // The default map color is white, and the placeholder is the only thing
        // that can paint the middle of the globe on frame one. Alpha is part of
        // the claim: a fully transparent white pixel would satisfy every RGB
        // check while the planet still read as a hole into whatever is behind
        // the drawable.
        XCTAssertGreaterThan(Int(center.red), 200)
        XCTAssertGreaterThan(Int(center.green), 200)
        XCTAssertGreaterThan(Int(center.blue), 200)
        XCTAssertGreaterThan(Int(center.alpha), 200)
    }

    /// The fill follows the configured map color rather than being hardcoded
    /// white, so a dark style does not flash a white planet while it loads.
    @MainActor
    func testPlaceholderFollowsTheConfiguredMapColor() async throws {
        var settings = ImmersiveMapSettings.default.earthScene(isEnabled: false)
        settings.scene.mapClearColor = SIMD4<Double>(0.1, 0.2, 0.6, 1.0)
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)
        harness.setZoom(1.0)

        let center = try await harness.renderFrame().center

        XCTAssertGreaterThan(Int(center.blue), Int(center.red))
        XCTAssertGreaterThan(Int(center.blue), Int(center.green))
    }

    /// With resident tiles covering the slots around the view centre, the
    /// tile geometry paints the sphere over the placeholder. The centre
    /// pixel must show painted, opaque surface: the sky draws after the
    /// surface and is clipped by the depth the placeholder grid wrote, so a
    /// break anywhere in that chain would paint space over the middle of
    /// the planet or leave a hole into the clear color.
    @MainActor
    func testCoveredSlotsStillPaintTheSphereThroughTheTile() async throws {
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: .default.earthScene(isEnabled: false))
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 55.75,
                                               longitudeDegrees: 37.61,
                                               zoom: 3.0)
        harness.setCameraPosition(camera)
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        let data = VectorTileFixture.fullCoverageTile(layerName: "water",
                                                      properties: ["class": "water"])
        let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: camera.latitudeDegrees,
                                                               longitude: camera.longitudeDegrees,
                                                               maximumZoom: 6)
        for tile in tiles {
            let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(didMaterialize, "Fixture tile \(tile.z)/\(tile.x)/\(tile.y) must parse")
        }
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                           startingAt: OffscreenFrameHarness.frameTime(1))

        let center = painted.center
        XCTAssertGreaterThan(Int(center.alpha), 200, "The middle of the planet must be opaque surface")
        XCTAssertGreaterThan(Int(center.red) + Int(center.green) + Int(center.blue), 150,
                             "The middle of the planet must be painted surface, not space")
    }
}
